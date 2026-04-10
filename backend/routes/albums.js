// routes/albums.js
//
// FIXES IN THIS VERSION
// =====================
//
// 1. SERVER-SIDE CACHE FOR /:id AND /:id/songs (NEW)
//    The Flutter client fires GET /api/albums/:id AND /api/albums/:id/songs for
//    every album on startup — 11 albums × 2 = 22 simultaneous requests.
//    HTTP Cache-Control headers don't help because Dio doesn't cache by default.
//    Added NodeCache entries for album detail (5 min) and songs (5 min) so the
//    second and subsequent requests return instantly from memory.
//
// 2. CACHE STAMPEDE PREVENTION (NEW)
//    When the server cold-starts and 11 parallel /api/albums requests arrive at
//    the same time, all miss the empty cache and all fire DB + Telegram calls
//    simultaneously. Fixed with an in-flight Map: if a cache miss is already
//    being resolved, subsequent callers await the same Promise instead of
//    starting a new one.
//
// 3. SONGS ENDPOINT COVER URL (FIXED)
//    The /:id/songs endpoint was calling getCoverUrl() once per request but
//    with no caching, every parallel song-list request hit Telegram.
//    Now the cover URL is resolved once from the shared telegram URL cache
//    and the whole songs response is cached for 5 minutes.
//
// 4. CACHE INVALIDATION (EXTENDED)
//    PATCH and DELETE now also invalidate the detail and songs caches for
//    that specific album, not just the list cache.

const express   = require('express');
const router    = express.Router();
const prisma    = require('../services/db');
const telegram  = require('../services/telegram');
const NodeCache = require('node-cache');

// ── Caches ────────────────────────────────────────────────────────────────────

// Album list: 60 s TTL (rarely changes; invalidated on mutation)
const listCache   = new NodeCache({ stdTTL: 60,  checkperiod: 30 });
// Album detail: 5 min TTL
const detailCache = new NodeCache({ stdTTL: 300, checkperiod: 60 });
// Album songs: 5 min TTL
const songsCache  = new NodeCache({ stdTTL: 300, checkperiod: 60 });

// In-flight map: prevents cache stampede when multiple requests arrive before
// the first one has populated the cache. Key → Promise.
const inFlight = new Map();

async function withCache(cache, key, fetcher) {
  const hit = cache.get(key);
  if (hit !== undefined) return { data: hit, fromCache: true };

  // If a request for this key is already in flight, join it.
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

// ── GET /api/albums ──────────────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const { data, fromCache } = await withCache(listCache, 'albums_list', async () => {
      const albums = await prisma.album.findMany({
        where:   { isActive: true },
        orderBy: { createdAt: 'desc' },
        include: { _count: { select: { songs: { where: { isActive: true } } } } },
      });

      // Resolve cover URLs in parallel — getCoverUrl is already cached 45 min
      // in telegram.js, so this is only slow on cold start.
      return Promise.all(
        albums.map(async (a) => {
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
    });

    res.setHeader('X-Cache', fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=60, stale-while-revalidate=30');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/albums/:id ──────────────────────────────────────────────────────
router.get('/:id', async (req, res, next) => {
  try {
    const cacheKey = `album:${req.params.id}`;

    const { data, fromCache } = await withCache(detailCache, cacheKey, async () => {
      const album = await prisma.album.findUnique({
        where:   { id: req.params.id },
        include: { _count: { select: { songs: { where: { isActive: true } } } } },
      });
      if (!album) return null;

      const coverUrl = await telegram.getCoverUrl(album.coverTelegramFileId);
      return {
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
      };
    });

    if (!data) return res.status(404).json({ error: 'Album not found' });

    res.setHeader('X-Cache', fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/albums/:id/songs ────────────────────────────────────────────────
router.get('/:id/songs', async (req, res, next) => {
  try {
    const cacheKey = `songs:${req.params.id}`;

    const { data, fromCache } = await withCache(songsCache, cacheKey, async () => {
      const album = await prisma.album.findUnique({ where: { id: req.params.id } });
      if (!album) return null;

      const songs = await prisma.song.findMany({
        where:   { albumId: req.params.id, isActive: true },
        orderBy: { trackNumber: 'asc' },
      });

      // Resolve cover URL once for the whole album — cached 45 min in telegram.js
      const coverUrl = await telegram.getCoverUrl(album.coverTelegramFileId);

      return songs.map((s) => ({
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
      }));
    });

    if (!data) return res.status(404).json({ error: 'Album not found' });

    res.setHeader('X-Cache', fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({ success: true, data });
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

    // Invalidate all caches for this album
    listCache.del('albums_list');
    detailCache.del(`album:${req.params.id}`);
    songsCache.del(`songs:${req.params.id}`);

    res.json({ success: true, data: album });
  } catch (err) { next(err); }
});

// ── DELETE /api/albums/:id ───────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.album.update({ where: { id: req.params.id }, data: { isActive: false } });

    listCache.del('albums_list');
    detailCache.del(`album:${req.params.id}`);
    songsCache.del(`songs:${req.params.id}`);

    res.json({ success: true, message: 'Album deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;