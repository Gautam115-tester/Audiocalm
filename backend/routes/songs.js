// routes/songs.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/songs/:id/stream
// Stream song audio to Flutter player
// Supports ?part=N for multi-part songs
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/stream', async (req, res) => {
  try {
    const song = await prisma.song.findUnique({
      where: { id: req.params.id },
    });

    if (!song) return res.status(404).json({ error: 'Song not found' });
    if (!song.telegramFileId) {
      return res.status(404).json({ error: 'Song audio not available' });
    }

    let fileId = song.telegramFileId;

    // Multi-part support
    if (song.partCount > 1 && req.query.part) {
      const partNum = parseInt(req.query.part, 10);
      if (isNaN(partNum) || partNum < 1 || partNum > song.partCount) {
        return res.status(400).json({ error: 'Invalid part number' });
      }
      try {
        const parts = JSON.parse(song.telegramFileId);
        fileId = parts[partNum - 1];
      } catch {
        fileId = song.telegramFileId;
      }
    }

    const rangeHeader = req.headers['range'];
    await telegram.streamFile(fileId, res, rangeHeader);
  } catch (err) {
    console.error('GET /api/songs/:id/stream error:', err);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Stream failed' });
    }
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/songs/:id/download
// Full download for Flutter offline mode
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/download', async (req, res) => {
  try {
    const song = await prisma.song.findUnique({
      where: { id: req.params.id },
    });

    if (!song) return res.status(404).json({ error: 'Song not found' });
    if (!song.telegramFileId) {
      return res.status(404).json({ error: 'Song audio not available' });
    }

    await telegram.downloadFile(song.telegramFileId, res);
  } catch (err) {
    console.error('GET /api/songs/:id/download error:', err);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Download failed' });
    }
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/songs/:id/parts
// Returns part count info
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/parts', async (req, res) => {
  try {
    const song = await prisma.song.findUnique({
      where: { id: req.params.id },
      select: { id: true, title: true, partCount: true, duration: true },
    });

    if (!song) return res.status(404).json({ error: 'Song not found' });
    res.json(song);
  } catch (err) {
    res.status(500).json({ error: 'Failed to get parts info' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/songs
// Create song record
// Body: { albumId, trackNumber, title, telegramFileId, duration, partCount }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/', async (req, res) => {
  try {
    const {
      albumId,
      trackNumber,
      title,
      telegramFileId,
      duration,
      partCount,
    } = req.body;

    if (!albumId || !trackNumber || !title) {
      return res.status(400).json({
        error: 'albumId, trackNumber and title are required',
      });
    }

    const song = await prisma.song.create({
      data: {
        albumId,
        trackNumber: parseInt(trackNumber),
        title,
        telegramFileId,
        duration:  duration  ? parseInt(duration)  : null,
        partCount: partCount ? parseInt(partCount) : 1,
      },
    });

    res.status(201).json(song);
  } catch (err) {
    console.error('POST /api/songs error:', err);
    res.status(500).json({ error: 'Failed to create song' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /api/songs/:id
// ─────────────────────────────────────────────────────────────────────────────
router.patch('/:id', async (req, res) => {
  try {
    const { title, telegramFileId, duration, partCount, isActive } = req.body;

    const song = await prisma.song.update({
      where: { id: req.params.id },
      data: {
        ...(title          !== undefined && { title }),
        ...(telegramFileId !== undefined && { telegramFileId }),
        ...(duration       !== undefined && { duration: parseInt(duration) }),
        ...(partCount      !== undefined && { partCount: parseInt(partCount) }),
        ...(isActive       !== undefined && { isActive }),
      },
    });

    res.json(song);
  } catch (err) {
    console.error('PATCH /api/songs/:id error:', err);
    res.status(500).json({ error: 'Failed to update song' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// DELETE /api/songs/:id  (soft delete)
// ─────────────────────────────────────────────────────────────────────────────
router.delete('/:id', async (req, res) => {
  try {
    await prisma.song.update({
      where: { id: req.params.id },
      data: { isActive: false },
    });
    res.json({ message: 'Song deactivated' });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete song' });
  }
});

module.exports = router;
