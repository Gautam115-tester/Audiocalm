// routes/albums.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/albums
// All active albums (used by Flutter MusicScreen & HomeScreen)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/', async (req, res) => {
  try {
    const albums = await prisma.album.findMany({
      where: { isActive: true },
      orderBy: { createdAt: 'desc' },
      include: {
        _count: { select: { songs: true } },
      },
    });

    const withCovers = await Promise.all(
      albums.map(async (a) => {
        const coverUrl = await telegram.getCoverUrl(a.coverTelegramFileId);
        return {
          id:         a.id,
          title:      a.title,
          artist:     a.artist,
          coverUrl,
          isActive:   a.isActive,
          trackCount: a._count.songs,
          createdAt:  a.createdAt,
        };
      })
    );

    res.json(withCovers);
  } catch (err) {
    console.error('GET /api/albums error:', err);
    res.status(500).json({ error: 'Failed to fetch albums' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/albums/:id
// Single album detail (used by Flutter AlbumDetailScreen)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id', async (req, res) => {
  try {
    const album = await prisma.album.findUnique({
      where: { id: req.params.id },
      include: {
        _count: { select: { songs: true } },
      },
    });

    if (!album) return res.status(404).json({ error: 'Album not found' });

    const coverUrl = await telegram.getCoverUrl(album.coverTelegramFileId);

    res.json({
      id:         album.id,
      title:      album.title,
      artist:     album.artist,
      coverUrl,
      isActive:   album.isActive,
      trackCount: album._count.songs,
      createdAt:  album.createdAt,
    });
  } catch (err) {
    console.error('GET /api/albums/:id error:', err);
    res.status(500).json({ error: 'Failed to fetch album' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/albums/:id/songs
// All songs in an album (used by Flutter AlbumDetailScreen song list)
// ─────────────────────────────────────────────────────────────────────────────
router.get('/:id/songs', async (req, res) => {
  try {
    const songs = await prisma.song.findMany({
      where: {
        albumId:  req.params.id,
        isActive: true,
      },
      orderBy: { trackNumber: 'asc' },
    });

    res.json(
      songs.map((s) => ({
        id:             s.id,
        albumId:        s.albumId,
        trackNumber:    s.trackNumber,
        title:          s.title,
        telegramFileId: s.telegramFileId,
        duration:       s.duration,
        partCount:      s.partCount,
        isActive:       s.isActive,
      }))
    );
  } catch (err) {
    console.error('GET /api/albums/:id/songs error:', err);
    res.status(500).json({ error: 'Failed to fetch songs' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/albums
// Create album
// Body: { title, artist }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/', async (req, res) => {
  try {
    const { title, artist } = req.body;
    if (!title) return res.status(400).json({ error: 'title is required' });

    const album = await prisma.album.create({
      data: { title, artist },
    });

    res.status(201).json(album);
  } catch (err) {
    console.error('POST /api/albums error:', err);
    res.status(500).json({ error: 'Failed to create album' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// PATCH /api/albums/:id
// Update album
// ─────────────────────────────────────────────────────────────────────────────
router.patch('/:id', async (req, res) => {
  try {
    const { title, artist, isActive, coverTelegramFileId } = req.body;

    const album = await prisma.album.update({
      where: { id: req.params.id },
      data: {
        ...(title                !== undefined && { title }),
        ...(artist               !== undefined && { artist }),
        ...(isActive             !== undefined && { isActive }),
        ...(coverTelegramFileId  !== undefined && { coverTelegramFileId }),
      },
    });

    res.json(album);
  } catch (err) {
    console.error('PATCH /api/albums/:id error:', err);
    res.status(500).json({ error: 'Failed to update album' });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// DELETE /api/albums/:id  (soft delete)
// ─────────────────────────────────────────────────────────────────────────────
router.delete('/:id', async (req, res) => {
  try {
    await prisma.album.update({
      where: { id: req.params.id },
      data: { isActive: false },
    });
    res.json({ message: 'Album deactivated' });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete album' });
  }
});

module.exports = router;
