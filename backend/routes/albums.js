// routes/albums.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ── GET /api/albums ──────────────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const albums = await prisma.album.findMany({
      where:   { isActive: true },
      orderBy: { createdAt: 'desc' },
      include: { _count: { select: { songs: { where: { isActive: true } } } } },
    });

    const data = await Promise.all(
      albums.map(async (a) => ({
        id:         a.id,
        title:      a.title,
        artist:     a.artist,
        genre:      a.genre,
        releaseYear: a.releaseYear,
        description: a.description,
        coverUrl:   await telegram.getCoverUrl(a.coverTelegramFileId),
        trackCount: a._count.songs,
        createdAt:  a.createdAt,
      }))
    );

    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/albums/:id ──────────────────────────────────────────────────────
router.get('/:id', async (req, res, next) => {
  try {
    const album = await prisma.album.findUnique({
      where:   { id: req.params.id },
      include: { _count: { select: { songs: { where: { isActive: true } } } } },
    });

    if (!album) return res.status(404).json({ error: 'Album not found' });

    res.json({
      success: true,
      data: {
        id:          album.id,
        title:       album.title,
        artist:      album.artist,
        genre:       album.genre,
        releaseYear: album.releaseYear,
        description: album.description,
        coverUrl:    await telegram.getCoverUrl(album.coverTelegramFileId),
        trackCount:  album._count.songs,
        isActive:    album.isActive,
        createdAt:   album.createdAt,
      },
    });
  } catch (err) { next(err); }
});

// ── GET /api/albums/:id/songs ────────────────────────────────────────────────
router.get('/:id/songs', async (req, res, next) => {
  try {
    const album = await prisma.album.findUnique({ where: { id: req.params.id } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    const songs = await prisma.song.findMany({
      where:   { albumId: req.params.id, isActive: true },
      orderBy: { trackNumber: 'asc' },
    });

    // Resolve album cover once — share across all songs
    // (per-song thumbnails are low-res; album cover is high-res)
    const coverUrl = await telegram.getCoverUrl(album.coverTelegramFileId);

    res.json({
      success: true,
      data: songs.map((s) => ({
        id:          s.id,
        albumId:     s.albumId,
        trackNumber: s.trackNumber,
        title:       s.title,
        artist:      s.artist || album.artist,
        duration:    s.duration,
        partCount:   s.partCount,
        isMultiPart: s.partCount > 1,
        coverUrl,    // album-level cover for all tracks
        createdAt:   s.createdAt,
      })),
    });
  } catch (err) { next(err); }
});

// ── POST /api/albums ─────────────────────────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const { title, artist, genre, releaseYear, description } = req.body;
    if (!title?.trim()) return res.status(400).json({ error: 'title is required' });

    const album = await prisma.album.create({
      data: {
        title:       title.trim(),
        artist:      artist?.trim()      || null,
        genre:       genre?.trim()       || null,
        releaseYear: releaseYear ? parseInt(releaseYear) : null,
        description: description?.trim() || null,
      },
    });

    res.status(201).json({ success: true, data: album });
  } catch (err) { next(err); }
});

// ── PATCH /api/albums/:id ────────────────────────────────────────────────────
router.patch('/:id', async (req, res, next) => {
  try {
    const { title, artist, genre, releaseYear, description, isActive, coverTelegramFileId } = req.body;

    const album = await prisma.album.update({
      where: { id: req.params.id },
      data: {
        ...(title               != null && { title: title.trim() }),
        ...(artist              != null && { artist }),
        ...(genre               != null && { genre }),
        ...(releaseYear         != null && { releaseYear: parseInt(releaseYear) }),
        ...(description         != null && { description }),
        ...(isActive            != null && { isActive }),
        ...(coverTelegramFileId != null && { coverTelegramFileId }),
      },
    });

    res.json({ success: true, data: album });
  } catch (err) { next(err); }
});

// ── DELETE /api/albums/:id ───────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.album.update({ where: { id: req.params.id }, data: { isActive: false } });
    res.json({ success: true, message: 'Album deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;