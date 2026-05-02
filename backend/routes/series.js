// routes/series.js
//
// FIXES IN THIS VERSION
// =====================
//
// FIX 1 — REMOVE ?t CACHE-BUSTER CACHE KEY (CRITICAL BACKEND FIX)
//    Uses a single stable cache key "all_with_episodes" instead of including
//    the ?t query parameter. The ?t param is intentionally IGNORED.
//
// FIX 2 — REDUCED allWithEpisodesCache TTL: 300s → 60s
//    Reduces the worst-case stale window from 5 minutes to 60 seconds.
//
// FIX 3 — BACKGROUND URL PRE-WARMING after all-with-episodes response
//    After building the response, resolves the Telegram CDN URL for the
//    first episode of each series so it's cached before the user taps play.
//    Completely non-blocking — fire and forget. Eliminates the 200–800ms
//    cold Telegram getFile delay on first playback.

const express   = require('express');
const router    = express.Router();
const prisma    = require('../services/db');
const telegram  = require('../services/telegram');
const NodeCache = require('node-cache');

// ── Caches ────────────────────────────────────────────────────────────────────
const listCache            = new NodeCache({ stdTTL: 60,  checkperiod: 30  });
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
// FIX 1: Single stable cache key "all_with_episodes" — ignore ?t param entirely.
// FIX 3: After responding, fires background URL pre-warm for first episode
//         of each series. Completely non-blocking.

router.get('/all-with-episodes', async (req, res, next) => {
  try {
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
            episodeCount: series.episodes.length,
            isActive:     series.isActive,
            createdAt:    series.createdAt,
            // Store first episode fileId for pre-warming (stripped before response)
            _firstEpFileId: series.episodes[0]?.telegramFileId || null,
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

    // Strip internal field before sending to client
    const clientData = data.map(({ _firstEpFileId, ...series }) => series);
    res.json({ success: true, data: clientData });

    // FIX 3: Fire background pre-warm AFTER responding (non-blocking)
    if (!fromCache) {
      const fileIds = data
        .map(s => {
          const raw = s._firstEpFileId;
          if (!raw) return null;
          if (raw.startsWith('[')) {
            try { return JSON.parse(raw)[0]; } catch { return null; }
          }
          return raw;
        })
        .filter(Boolean)
        .slice(0, 8);

      if (fileIds.length > 0) {
        telegram.warmUrlsBackground(fileIds);
      }
    }
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