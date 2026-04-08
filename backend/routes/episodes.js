// routes/episodes.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/episodes/:id/stream
// Stream episode audio to Flutter player
// Supports ?part=N for multi-part episodes
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/stream', async (req, res) => {
  try {
    const episode = await prisma.episode.findUnique({
      where: { id: req.params.id },
    });

    if (!episode) return res.status(404).json({ error: 'Episode not found' });
    if (!episode.telegramFileId) {
      return res.status(404).json({ error: 'Episode audio not available' });
    }

    // Multi-part support: ?part=1, ?part=2 ...
    let fileId = episode.telegramFileId;

    if (episode.partCount > 1 && req.query.part) {
      const partNum = parseInt(req.query.part, 10);
      if (isNaN(partNum) || partNum < 1 || partNum > episode.partCount) {
        return res.status(400).json({ error: 'Invalid part number' });
      }
      // Parts are stored as JSON array in telegramFileId field
      // e.g. telegramFileId = '["fileId1","fileId2","fileId3"]'
      try {
        const parts = JSON.parse(episode.telegramFileId);
        fileId = parts[partNum - 1];
      } catch {
        // Single file ID used for all parts (legacy)
        fileId = episode.telegramFileId;
      }
    }

    const rangeHeader = req.headers['range'];
    await telegram.streamFile(fileId, res, rangeHeader);
  } catch (err) {
    console.error('GET /api/episodes/:id/stream error:', err);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Stream failed' });
    }
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/episodes/:id/download
// Full download for offline use (Flutter download manager)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/download', async (req, res) => {
  try {
    const episode = await prisma.episode.findUnique({
      where: { id: req.params.id },
    });

    if (!episode) return res.status(404).json({ error: 'Episode not found' });
    if (!episode.telegramFileId) {
      return res.status(404).json({ error: 'Episode audio not available' });
    }

    await telegram.downloadFile(episode.telegramFileId, res);
  } catch (err) {
    console.error('GET /api/episodes/:id/download error:', err);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Download failed' });
    }
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/episodes/:id/parts
// Returns part count info (Flutter uses partCount from series detail already,
// but this is a convenience endpoint)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/parts', async (req, res) => {
  try {
    const episode = await prisma.episode.findUnique({
      where: { id: req.params.id },
      select: { id: true, title: true, partCount: true, duration: true },
    });

    if (!episode) return res.status(404).json({ error: 'Episode not found' });
    res.json(episode);
  } catch (err) {
    res.status(500).json({ error: 'Failed to get parts info' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/episodes
// Create episode record (after audio is already uploaded via /api/upload)
// Body: { seriesId, episodeNumber, title, telegramFileId, duration, partCount }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/', async (req, res) => {
  try {
    const {
      seriesId,
      episodeNumber,
      title,
      telegramFileId,
      duration,
      partCount,
    } = req.body;

    if (!seriesId || !episodeNumber || !title) {
      return res.status(400).json({
        error: 'seriesId, episodeNumber and title are required',
      });
    }

    const episode = await prisma.episode.create({
      data: {
        seriesId,
        episodeNumber: parseInt(episodeNumber),
        title,
        telegramFileId,
        duration:  duration  ? parseInt(duration)  : null,
        partCount: partCount ? parseInt(partCount) : 1,
      },
    });

    res.status(201).json(episode);
  } catch (err) {
    console.error('POST /api/episodes error:', err);
    res.status(500).json({ error: 'Failed to create episode' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /api/episodes/:id
// Update episode metadata
// ─────────────────────────────────────────────────────────────────────────────
router.patch('/:id', async (req, res) => {
  try {
    const { title, telegramFileId, duration, partCount, isActive } = req.body;

    const episode = await prisma.episode.update({
      where: { id: req.params.id },
      data: {
        ...(title          !== undefined && { title }),
        ...(telegramFileId !== undefined && { telegramFileId }),
        ...(duration       !== undefined && { duration: parseInt(duration) }),
        ...(partCount      !== undefined && { partCount: parseInt(partCount) }),
        ...(isActive       !== undefined && { isActive }),
      },
    });

    res.json(episode);
  } catch (err) {
    console.error('PATCH /api/episodes/:id error:', err);
    res.status(500).json({ error: 'Failed to update episode' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// DELETE /api/episodes/:id  (soft delete)
// ─────────────────────────────────────────────────────────────────────────────
router.delete('/:id', async (req, res) => {
  try {
    await prisma.episode.update({
      where: { id: req.params.id },
      data: { isActive: false },
    });
    res.json({ message: 'Episode deactivated' });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete episode' });
  }
});

module.exports = router;
