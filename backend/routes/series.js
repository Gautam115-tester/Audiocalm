// routes/series.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ── Helper: attach live coverUrl from Telegram ────────────────────────────────
async function attachCoverUrl(series) {
  if (!series) return null;
  const coverUrl = await telegram.getCoverUrl(series.coverTelegramFileId);
  return { ...series, coverUrl };
}

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/series
// Returns all active series (used by Flutter StoriesScreen & HomeScreen)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/', async (req, res) => {
  try {
    const allSeries = await prisma.series.findMany({
      where: { isActive: true },
      orderBy: { createdAt: 'desc' },
      include: {
        _count: { select: { episodes: true } },
      },
    });

    // Attach live Telegram cover URLs
    const withCovers = await Promise.all(
      allSeries.map(async (s) => {
        const coverUrl = await telegram.getCoverUrl(s.coverTelegramFileId);
        return {
          id:           s.id,
          title:        s.title,
          description:  s.description,
          coverUrl,
          isActive:     s.isActive,
          episodeCount: s._count.episodes,
          createdAt:    s.createdAt,
        };
      })
    );

    res.json(withCovers);
  } catch (err) {
    console.error('GET /api/series error:', err);
    res.status(500).json({ error: 'Failed to fetch series' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/series/:id
// Single series detail (used by Flutter SeriesDetailScreen)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id', async (req, res) => {
  try {
    const series = await prisma.series.findUnique({
      where: { id: req.params.id },
      include: {
        _count: { select: { episodes: true } },
      },
    });

    if (!series) return res.status(404).json({ error: 'Series not found' });

    const coverUrl = await telegram.getCoverUrl(series.coverTelegramFileId);

    res.json({
      id:           series.id,
      title:        series.title,
      description:  series.description,
      coverUrl,
      isActive:     series.isActive,
      episodeCount: series._count.episodes,
      createdAt:    series.createdAt,
    });
  } catch (err) {
    console.error('GET /api/series/:id error:', err);
    res.status(500).json({ error: 'Failed to fetch series' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/series/:id/episodes
// All episodes for a series (used by Flutter SeriesDetailScreen episode list)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/episodes', async (req, res) => {
  try {
    const episodes = await prisma.episode.findMany({
      where: {
        seriesId: req.params.id,
        isActive: true,
      },
      orderBy: { episodeNumber: 'asc' },
    });

    res.json(
      episodes.map((ep) => ({
        id:             ep.id,
        seriesId:       ep.seriesId,
        episodeNumber:  ep.episodeNumber,
        title:          ep.title,
        telegramFileId: ep.telegramFileId,
        duration:       ep.duration,
        partCount:      ep.partCount,
        isActive:       ep.isActive,
      }))
    );
  } catch (err) {
    console.error('GET /api/series/:id/episodes error:', err);
    res.status(500).json({ error: 'Failed to fetch episodes' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/series
// Create a new series (admin use)
// Body: { title, description }
// coverTelegramFileId is set via the upload route separately
// ─────────────────────────────────────────────────────────────────────────────
router.post('/', async (req, res) => {
  try {
    const { title, description } = req.body;
    if (!title) return res.status(400).json({ error: 'title is required' });

    const series = await prisma.series.create({
      data: { title, description },
    });

    res.status(201).json(series);
  } catch (err) {
    console.error('POST /api/series error:', err);
    res.status(500).json({ error: 'Failed to create series' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /api/series/:id
// Update series (title, description, isActive, coverTelegramFileId)
// ─────────────────────────────────────────────────────────────────────────────
router.patch('/:id', async (req, res) => {
  try {
    const { title, description, isActive, coverTelegramFileId } = req.body;

    const series = await prisma.series.update({
      where: { id: req.params.id },
      data: {
        ...(title                !== undefined && { title }),
        ...(description         !== undefined && { description }),
        ...(isActive            !== undefined && { isActive }),
        ...(coverTelegramFileId !== undefined && { coverTelegramFileId }),
      },
    });

    res.json(series);
  } catch (err) {
    console.error('PATCH /api/series/:id error:', err);
    res.status(500).json({ error: 'Failed to update series' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// DELETE /api/series/:id
// Soft delete (sets isActive = false)
// ─────────────────────────────────────────────────────────────────────────────
router.delete('/:id', async (req, res) => {
  try {
    await prisma.series.update({
      where: { id: req.params.id },
      data: { isActive: false },
    });
    res.json({ message: 'Series deactivated' });
  } catch (err) {
    console.error('DELETE /api/series/:id error:', err);
    res.status(500).json({ error: 'Failed to delete series' });
  }
});

module.exports = router;
