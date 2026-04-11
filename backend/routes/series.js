// routes/series.js
//
// FIXES IN THIS VERSION
// =====================
//
// FIX 1 — REMOVE ?t CACHE-BUSTER CACHE KEY (CRITICAL BACKEND FIX)
// ----------------------------------------------------------------
// PROBLEM: The previous version used the Flutter ?t query param as part of
// the NodeCache key: `all_with_episodes_${t}`
//
// This created UNBOUNDED cache slots:
//   - Flutter sends ?t=100 → cached as "all_with_episodes_100" (5min TTL)
//   - Flutter sends ?t=101 → cached as "all_with_episodes_101" (5min TTL)
//   - Flutter sends ?t=102 → cached as "all_with_episodes_102" (5min TTL)
//   ...up to 10 simultaneous stale slots within a 5-minute window
//
// When admin syncs ep 81 → invalidateSeriesCache() → flushAll() ✓ (all cleared)
// But THEN Flutter immediately re-requests with the same ?t=100 value
// (it's still within the same 30s epoch window).
// The cache slot "all_with_episodes_100" was just flushed → MISS → DB query
// → fresh data with 81 episodes. This actually works...
//
// BUT: If Flutter sends a NEW epoch ?t=101 AFTER the cache was populated with
// ?t=100 but BEFORE the sync happened, then:
//   - ?t=100 → DB query → 80 eps cached
//   - Admin syncs → flushAll() clears everything ✓
//   - Flutter now in epoch 101 → ?t=101 → MISS → DB query → 81 eps ✓
// This also works...
//
// The REAL problem the ?t approach caused: It prevented the server-side cache
// from being effective at all. Each new 30s epoch = guaranteed cache miss =
// guaranteed DB query every 30 seconds per user, even for identical data.
// At 10,000 users this is a significant unnecessary DB load.
//
// FIX: Use a single stable cache key "all_with_episodes".
// The cache is properly invalidated by invalidateSeriesCache() → flushAll()
// which clears it after every sync. This is the correct design:
//   - One cache entry, one invalidation point
//   - TTL of 60s (reduced from 300s so stale window is at most 60s)
//   - After a sync, the next request always hits DB and gets fresh data
//
// FIX 2 — REDUCED allWithEpisodesCache TTL: 300s → 60s
// ------------------------------------------------------
// Reduces the worst-case stale window from 5 minutes to 60 seconds.
// If a sync happens and invalidateSeriesCache() is called, the cache is
// immediately flushed. If somehow it isn't called (edge case), the data
// will be at most 60 seconds stale.
//
// All existing routes are unchanged.

const express   = require('express');
const router    = express.Router();
const prisma    = require('../services/db');
const telegram  = require('../services/telegram');
const NodeCache = require('node-cache');

// ── Caches ────────────────────────────────────────────────────────────────────
const listCache            = new NodeCache({ stdTTL: 60,  checkperiod: 30  });
// FIX 2: Reduced TTL from 300s to 60s — reduces worst-case stale window.
const allWithEpisodesCache = new NodeCache({ stdTTL: 60,  checkperiod: 30  });
const detailCache          = new NodeCache({ stdTTL: 300, checkperiod: 60  });
const episodesCache        = new NodeCache({ stdTTL: 300, checkperiod: 60  });

const inFlight = new Map();

async function withCache(cache, key, fetcher) {
  const hit = cache.get(key);
  if (hit !== undefined) return { data: hit, fromCache: true };

  if (inFlight.has(key)) {
    const data = await inFlight.get(key);
    return { data, fromCache: false };
  }

  const promise = fetcher();
  inFlight.set(key, promise);
  try {
    const data = await promise;
    cache.set(key, data);
    return { data, fromCache: false };
  } finally {
    inFlight.delete(key);
  }
}

function invalidateSeries(id) {
  listCache.del('series_list');
  // Flush ALL keys in allWithEpisodesCache.
  allWithEpisodesCache.flushAll();
  if (id) {
    detailCache.del(`series:${id}`);
    episodesCache.del(`episodes:${id}`);
  }
}

function invalidateSeriesCache() {
  listCache.flushAll();
  allWithEpisodesCache.flushAll();
  detailCache.flushAll();
  episodesCache.flushAll();
}

// ── GET /api/series/all-with-episodes ─────────────────────────────────────────
//
// FIX 1: Uses a single stable cache key "all_with_episodes" instead of
// including the ?t query parameter in the key.
//
// The ?t param is intentionally IGNORED for caching purposes.
// It was sent by older Flutter builds as a cache-buster; ignoring it here
// means the server cache works correctly with a single invalidation point.
//
// Result: one cache entry, invalidated cleanly by invalidateSeriesCache()
// after every sync. TTL is 60s so data is at most 60s stale even without
// an explicit invalidation.

router.get('/all-with-episodes', async (req, res, next) => {
  try {
    // FIX 1: Single stable cache key — ignore ?t param entirely.
    const cacheKey = 'all_with_episodes';

    const { data, fromCache } = await withCache(allWithEpisodesCache, cacheKey, async () => {
      const allSeries = await prisma.series.findMany({
        where:   { isActive: true },
        orderBy: { createdAt: 'desc' },
        include: {
          episodes: {
            where:   { isActive: true },
            orderBy: { episodeNumber: 'asc' },
          },
        },
      });

      return Promise.all(
        allSeries.map(async (series) => {
          const coverUrl = series.coverTelegramFileId
            ? await telegram.getCoverUrl(series.coverTelegramFileId).catch(() => null)
            : null;

          return {
            id:           series.id,
            title:        series.title,
            description:  series.description,
            coverUrl,
            // Always derive episodeCount from the live embedded list.
            // Never return the potentially-stale series.episodeCount DB column.
            episodeCount: series.episodes.length,
            isActive:     series.isActive,
            createdAt:    series.createdAt,
            episodes: series.episodes.map((ep) => ({
              id:            ep.id,
              seriesId:      ep.seriesId,
              episodeNumber: ep.episodeNumber,
              title:         ep.title,
              description:   ep.description,
              duration:      ep.duration,
              partCount:     ep.partCount,
              isMultiPart:   ep.partCount > 1,
              createdAt:     ep.createdAt,
            })),
          };
        })
      );
    });

    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=60, stale-while-revalidate=30');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/series ──────────────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const { data, fromCache } = await withCache(listCache, 'series_list', async () => {
      const allSeries = await prisma.series.findMany({
        where:   { isActive: true },
        orderBy: { createdAt: 'desc' },
        include: { _count: { select: { episodes: { where: { isActive: true } } } } },
      });

      return Promise.all(
        allSeries.map(async (s) => {
          const coverUrl = s.coverTelegramFileId
            ? await telegram.getCoverUrl(s.coverTelegramFileId).catch(() => null)
            : null;
          return {
            id:           s.id,
            title:        s.title,
            description:  s.description,
            coverUrl,
            episodeCount: s._count.episodes,
            createdAt:    s.createdAt,
          };
        })
      );
    });

    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=60, stale-while-revalidate=30');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/series/:id ──────────────────────────────────────────────────────
router.get('/:id', async (req, res, next) => {
  try {
    const cacheKey = `series:${req.params.id}`;

    const { data, fromCache } = await withCache(detailCache, cacheKey, async () => {
      const series = await prisma.series.findUnique({
        where:   { id: req.params.id },
        include: { _count: { select: { episodes: { where: { isActive: true } } } } },
      });
      if (!series) return null;

      const coverUrl = await telegram.getCoverUrl(series.coverTelegramFileId);
      return {
        id:           series.id,
        title:        series.title,
        description:  series.description,
        coverUrl,
        episodeCount: series._count.episodes,
        isActive:     series.isActive,
        createdAt:    series.createdAt,
      };
    });

    if (!data) return res.status(404).json({ error: 'Series not found' });

    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/series/:id/episodes ─────────────────────────────────────────────
router.get('/:id/episodes', async (req, res, next) => {
  try {
    const cacheKey = `episodes:${req.params.id}`;

    const { data, fromCache } = await withCache(episodesCache, cacheKey, async () => {
      const episodes = await prisma.episode.findMany({
        where:   { seriesId: req.params.id, isActive: true },
        orderBy: { episodeNumber: 'asc' },
      });
      return episodes.map((ep) => ({
        id:            ep.id,
        seriesId:      ep.seriesId,
        episodeNumber: ep.episodeNumber,
        title:         ep.title,
        description:   ep.description,
        duration:      ep.duration,
        partCount:     ep.partCount,
        isMultiPart:   ep.partCount > 1,
        createdAt:     ep.createdAt,
      }));
    });

    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── POST /api/series ─────────────────────────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const { title, description } = req.body;
    if (!title?.trim()) return res.status(400).json({ error: 'title is required' });
    const series = await prisma.series.create({
      data: { title: title.trim(), description: description?.trim() || null },
    });
    invalidateSeries(series.id);
    res.status(201).json({ success: true, data: series });
  } catch (err) { next(err); }
});

// ── PATCH /api/series/:id ────────────────────────────────────────────────────
router.patch('/:id', async (req, res, next) => {
  try {
    const { title, description, isActive, coverTelegramFileId } = req.body;
    const series = await prisma.series.update({
      where: { id: req.params.id },
      data: {
        ...(title               != null && { title: title.trim() }),
        ...(description         != null && { description }),
        ...(isActive            != null && { isActive }),
        ...(coverTelegramFileId != null && { coverTelegramFileId }),
      },
    });
    invalidateSeries(req.params.id);
    res.json({ success: true, data: series });
  } catch (err) { next(err); }
});

// ── DELETE /api/series/:id ────────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.series.update({ where: { id: req.params.id }, data: { isActive: false } });
    invalidateSeries(req.params.id);
    res.json({ success: true, message: 'Series deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;
module.exports.invalidateSeriesCache = invalidateSeriesCache;