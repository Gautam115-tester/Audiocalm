// routes/series.js
// PERF FIX: Same caching pattern as albums.js

const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');
const NodeCache = require('node-cache');

const listCache = new NodeCache({ stdTTL: 60, checkperiod: 30 });

// ── GET /api/series ──────────────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const cached = listCache.get('series_list');
    if (cached) {
      res.setHeader('X-Cache', 'HIT');
      return res.json({ success: true, data: cached });
    }

    const allSeries = await prisma.series.findMany({
      where:   { isActive: true },
      orderBy: { createdAt: 'desc' },
      include: { _count: { select: { episodes: { where: { isActive: true } } } } },
    });

    const data = await Promise.all(
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

    listCache.set('series_list', data);
    res.setHeader('Cache-Control', 'public, max-age=60, stale-while-revalidate=30');
    res.setHeader('X-Cache', 'MISS');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/series/:id ──────────────────────────────────────────────────────
router.get('/:id', async (req, res, next) => {
  try {
    const series = await prisma.series.findUnique({
      where:   { id: req.params.id },
      include: { _count: { select: { episodes: { where: { isActive: true } } } } },
    });

    if (!series) return res.status(404).json({ error: 'Series not found' });

    const coverUrl = await telegram.getCoverUrl(series.coverTelegramFileId);

    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({
      success: true,
      data: {
        id:           series.id,
        title:        series.title,
        description:  series.description,
        coverUrl,
        episodeCount: series._count.episodes,
        isActive:     series.isActive,
        createdAt:    series.createdAt,
      },
    });
  } catch (err) { next(err); }
});

// ── GET /api/series/:id/episodes ─────────────────────────────────────────────
router.get('/:id/episodes', async (req, res, next) => {
  try {
    const episodes = await prisma.episode.findMany({
      where:   { seriesId: req.params.id, isActive: true },
      orderBy: { episodeNumber: 'asc' },
    });

    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({
      success: true,
      data: episodes.map((ep) => ({
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
    });
  } catch (err) { next(err); }
});

// ── POST /api/series ─────────────────────────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const { title, description } = req.body;
    if (!title?.trim()) return res.status(400).json({ error: 'title is required' });
    const series = await prisma.series.create({ data: { title: title.trim(), description: description?.trim() || null } });
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
    res.json({ success: true, data: series });
  } catch (err) { next(err); }
});

// ── DELETE /api/series/:id  (soft delete) ────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.series.update({ where: { id: req.params.id }, data: { isActive: false } });
    listCache.del('series_list');
    res.json({ success: true, message: 'Series deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;