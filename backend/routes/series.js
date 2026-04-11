// routes/series.js
//
// FIX: Episode count stale (shows 80 instead of 81)
// ==================================================
//
// ROOT CAUSE:
//   allWithEpisodesCache has a 5-minute TTL. When a new episode is synced via
//   POST /api/sync/stories, the sync route calls prisma.episode.createMany()
//   but never calls invalidateSeries(). So the cache keeps serving the old
//   all-with-episodes payload (with 80 episodes) for up to 5 more minutes.
//
// FIX:
//   1. Export `invalidateSeriesCache()` so sync.js can call it after a
//      successful stories sync.
//   2. The Flutter provider also adds a ?t=<minute> cache-buster param so
//      even if NodeCache isn't invalidated immediately, a fresh minute always
//      bypasses it. The cache key now includes the query string.
//
// All existing routes are unchanged.

const express   = require('express');
const router    = express.Router();
const prisma    = require('../services/db');
const telegram  = require('../services/telegram');
const NodeCache = require('node-cache');

// ── Caches ────────────────────────────────────────────────────────────────────
const listCache            = new NodeCache({ stdTTL: 60,  checkperiod: 30  });
const allWithEpisodesCache = new NodeCache({ stdTTL: 300, checkperiod: 60  });
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
  // FIX: flush ALL keys in allWithEpisodesCache (there may be keys with
  // different ?t= values from the Flutter cache-buster param).
  allWithEpisodesCache.flushAll();
  if (id) {
    detailCache.del(`series:${id}`);
    episodesCache.del(`episodes:${id}`);
  }
}

// FIX: exported so sync.js can call it after a successful stories sync.
// This ensures that a newly-synced episode 81 is visible immediately,
// not after the 5-minute cache TTL expires.
function invalidateSeriesCache() {
  listCache.flushAll();
  allWithEpisodesCache.flushAll();
  detailCache.flushAll();
  episodesCache.flushAll();
}

// ── GET /api/series/all-with-episodes ─────────────────────────────────────────
// FIX: cache key now includes ?t query param (Flutter cache-buster).
// This ensures different minute-epoch values don't accidentally share stale data.
router.get('/all-with-episodes', async (req, res, next) => {
  try {
    // Include the ?t param in the cache key so each minute gets fresh data
    // when Flutter sends a new cache-buster value.
    const t = req.query.t || 'default';
    const cacheKey = `all_with_episodes_${t}`;

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
            // FIX: always derive episodeCount from the live embedded list,
            // never from the potentially-stale series.episodeCount DB column.
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