// routes/series.js
//
// FIXES IN THIS VERSION (mirrors albums.js fixes)
// ================================================
//
// 1. SERVER-SIDE CACHE FOR /:id AND /:id/episodes (NEW)
//    /:id and /:id/episodes had no in-memory cache — only HTTP headers that
//    Dio ignores. Added 5-minute NodeCache entries for both.
//
// 2. CACHE STAMPEDE PREVENTION (NEW)
//    Same withCache() helper as albums.js. Multiple parallel requests for the
//    same key share one Promise instead of each doing a full DB + Telegram hit.
//
// 3. CACHE INVALIDATION (EXTENDED)
//    PATCH and DELETE now also invalidate detail and episodes caches.

const express   = require('express');
const router    = express.Router();
const prisma    = require('../services/db');
const telegram  = require('../services/telegram');
const NodeCache = require('node-cache');

// ── Caches ────────────────────────────────────────────────────────────────────
const listCache     = new NodeCache({ stdTTL: 60,  checkperiod: 30 });
const detailCache   = new NodeCache({ stdTTL: 300, checkperiod: 60 });
const episodesCache = new NodeCache({ stdTTL: 300, checkperiod: 60 });

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

    res.setHeader('X-Cache', fromCache ? 'HIT' : 'MISS');
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

    res.setHeader('X-Cache', fromCache ? 'HIT' : 'MISS');
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

    res.setHeader('X-Cache', fromCache ? 'HIT' : 'MISS');
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
    listCache.del('series_list');
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

    listCache.del('series_list');
    detailCache.del(`series:${req.params.id}`);
    episodesCache.del(`episodes:${req.params.id}`);

    res.json({ success: true, data: series });
  } catch (err) { next(err); }
});

// ── DELETE /api/series/:id ────────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.series.update({ where: { id: req.params.id }, data: { isActive: false } });

    listCache.del('series_list');
    detailCache.del(`series:${req.params.id}`);
    episodesCache.del(`episodes:${req.params.id}`);

    res.json({ success: true, message: 'Series deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;