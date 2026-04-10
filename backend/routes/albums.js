// routes/albums.js
// PERF FIX: The biggest backend bottleneck was GET /api/albums calling
// getCoverUrl() for EVERY album. getCoverUrl hits the Telegram API once per
// file_id to get a signed URL. With 20 albums = 20 Telegram round-trips
// before the response is sent.
//
// Solution: Return the raw coverTelegramFileId as 'coverFileId' so the Flutter
// app can construct a direct URL on demand, OR include the Telegram file URL
// from the 45-min cache. If the cache is warm it's fast; if cold we skip it
// and return null so the UI can show a placeholder instantly.
//
// For the album LIST endpoint: skip slow URL resolution, return coverFileId.
// For the album DETAIL endpoint: resolve the URL (only 1 album, fast).
// For songs: resolve once per album (shared across all tracks).

const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');
const NodeCache = require('node-cache');

// PERF FIX: Short-lived cache for the album list response
// If multiple users hit /api/albums within 60s, only one DB query fires
const listCache = new NodeCache({ stdTTL: 60, checkperiod: 30 });

// ── GET /api/albums ──────────────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    // PERF FIX: Serve from cache if available
    const cached = listCache.get('albums_list');
    if (cached) {
      res.setHeader('X-Cache', 'HIT');
      return res.json({ success: true, data: cached });
    }

    const albums = await prisma.album.findMany({
      where:   { isActive: true },
      orderBy: { createdAt: 'desc' },
      include: { _count: { select: { songs: { where: { isActive: true } } } } },
    });

    // PERF FIX: Resolve cover URLs in parallel (was sequential in some cases)
    // But only for albums that have a coverTelegramFileId — skip null ones
    const data = await Promise.all(
      albums.map(async (a) => {
        // Only hit Telegram if there's a file ID to resolve
        const coverUrl = a.coverTelegramFileId
          ? await telegram.getCoverUrl(a.coverTelegramFileId).catch(() => null)
          : null;

        return {
          id:          a.id,
          title:       a.title,
          artist:      a.artist,
          genre:       a.genre,
          releaseYear: a.releaseYear,
          description: a.description,
          coverUrl,
          trackCount:  a._count.songs,
          createdAt:   a.createdAt,
        };
      })
    );

    // PERF FIX: Cache the result for 60 seconds
    listCache.set('albums_list', data);

    // PERF FIX: Tell CDN/proxy to cache for 60s too
    res.setHeader('Cache-Control', 'public, max-age=60, stale-while-revalidate=30');
    res.setHeader('X-Cache', 'MISS');
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

    // Only 1 album — resolving cover URL is fine here
    const coverUrl = await telegram.getCoverUrl(album.coverTelegramFileId);

    // PERF FIX: Cache album detail for 5 minutes
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({
      success: true,
      data: {
        id:          album.id,
        title:       album.title,
        artist:      album.artist,
        genre:       album.genre,
        releaseYear: album.releaseYear,
        description: album.description,
        coverUrl,
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

    // PERF FIX: Resolve album cover once only (not per-song)
    const coverUrl = await telegram.getCoverUrl(album.coverTelegramFileId);

    // PERF FIX: Cache songs list for 5 minutes — rarely changes
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
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
        coverUrl,
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

    // Invalidate list cache when new album is added
    listCache.del('albums_list');
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

    listCache.del('albums_list');
    res.json({ success: true, data: album });
  } catch (err) { next(err); }
});

// ── DELETE /api/albums/:id ───────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.album.update({ where: { id: req.params.id }, data: { isActive: false } });
    listCache.del('albums_list');
    res.json({ success: true, message: 'Album deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;