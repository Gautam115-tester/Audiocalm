// routes/series.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ── GET /api/series ──────────────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const allSeries = await prisma.series.findMany({
      where:   { isActive: true },
      orderBy: { createdAt: 'desc' },
      include: { _count: { select: { episodes: { where: { isActive: true } } } } },
    });

    const data = await Promise.all(
      allSeries.map(async (s) => ({
        id:           s.id,
        title:        s.title,
        description:  s.description,
        coverUrl:     await telegram.getCoverUrl(s.coverTelegramFileId),
        episodeCount: s._count.episodes,
        createdAt:    s.createdAt,
      }))
    );

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

    res.json({
      success: true,
      data: {
        id:           series.id,
        title:        series.title,
        description:  series.description,
        coverUrl:     await telegram.getCoverUrl(series.coverTelegramFileId),
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
        ...(title                != null && { title: title.trim() }),
        ...(description          != null && { description }),
        ...(isActive             != null && { isActive }),
        ...(coverTelegramFileId  != null && { coverTelegramFileId }),
      },
    });

    res.json({ success: true, data: series });
  } catch (err) { next(err); }
});

// ── DELETE /api/series/:id  (soft delete) ────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.series.update({ where: { id: req.params.id }, data: { isActive: false } });
    res.json({ success: true, message: 'Series deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;