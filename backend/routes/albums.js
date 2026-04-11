// routes/albums.js
//
// FIXES IN THIS VERSION
// =====================
//
// 1. NEW: GET /api/albums/all-with-songs  ← THE PRIMARY FIX
//    Returns ALL albums + their songs in a SINGLE database query.
//    Flutter currently fires: 1 list + 11×2 detail/songs = 23 requests on startup.
//    With this endpoint: 1 request → done. No parallel flood, no P2024 timeouts.
//    Flutter should call this INSTEAD of the separate list + per-album requests.
//    Response: { success: true, data: [ { ...album, coverUrl, songs: [...] } ] }
//    Cached 5 minutes server-side.
//
// 2. CACHE STAMPEDE PREVENTION (withCache helper)
//    Multiple cold-start requests for the same key share one Promise.
//
// 3. SERVER-SIDE CACHE FOR /:id AND /:id/songs
//    5-minute NodeCache (Dio ignores HTTP Cache-Control headers).
//
// 4. CACHE INVALIDATION via invalidateAlbum() on all mutations.

const express   = require('express');
const router    = express.Router();
const prisma    = require('../services/db');
const telegram  = require('../services/telegram');
const NodeCache = require('node-cache');

const listCache        = new NodeCache({ stdTTL: 60,  checkperiod: 30 });
const allWithSongCache = new NodeCache({ stdTTL: 300, checkperiod: 60 });
const detailCache      = new NodeCache({ stdTTL: 300, checkperiod: 60 });
const songsCache       = new NodeCache({ stdTTL: 300, checkperiod: 60 });

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

function invalidateAlbum(id) {
  listCache.del('albums_list');
  allWithSongCache.del('all_with_songs');
  if (id) {
    detailCache.del(`album:${id}`);
    songsCache.del(`songs:${id}`);
  }
}

// ── GET /api/albums/all-with-songs ───────────────────────────────────────────
// PRIMARY FIX: single endpoint replaces 23 parallel startup requests.
// Flutter calls this ONCE and gets everything it needs.
router.get('/all-with-songs', async (req, res, next) => {
  try {
    const { data, fromCache } = await withCache(allWithSongCache, 'all_with_songs', async () => {
      const albums = await prisma.album.findMany({
        where:   { isActive: true },
        orderBy: { createdAt: 'desc' },
        include: {
          songs: {
            where:   { isActive: true },
            orderBy: { trackNumber: 'asc' },
          },
        },
      });

      return Promise.all(
        albums.map(async (album) => {
          const coverUrl = album.coverTelegramFileId
            ? await telegram.getCoverUrl(album.coverTelegramFileId).catch(() => null)
            : null;
          return {
            id:          album.id,
            title:       album.title,
            artist:      album.artist,
            genre:       album.genre,
            releaseYear: album.releaseYear,
            description: album.description,
            coverUrl,
            trackCount:  album.songs.length,
            createdAt:   album.createdAt,
            songs: album.songs.map((s) => ({
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
          };
        })
      );
    });

    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/albums ──────────────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const { data, fromCache } = await withCache(listCache, 'albums_list', async () => {
      const albums = await prisma.album.findMany({
        where:   { isActive: true },
        orderBy: { createdAt: 'desc' },
        include: { _count: { select: { songs: { where: { isActive: true } } } } },
      });
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

    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=60, stale-while-revalidate=30');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/albums/:id ──────────────────────────────────────────────────────
router.get('/:id', async (req, res, next) => {
  try {
    const { data, fromCache } = await withCache(
      detailCache, `album:${req.params.id}`,
      async () => {
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
      }
    );

    if (!data) return res.status(404).json({ error: 'Album not found' });
    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
    res.setHeader('Cache-Control', 'public, max-age=300, stale-while-revalidate=60');
    res.json({ success: true, data });
  } catch (err) { next(err); }
});

// ── GET /api/albums/:id/songs ────────────────────────────────────────────────
router.get('/:id/songs', async (req, res, next) => {
  try {
    const { data, fromCache } = await withCache(
      songsCache, `songs:${req.params.id}`,
      async () => {
        const album = await prisma.album.findUnique({ where: { id: req.params.id } });
        if (!album) return null;
        const songs = await prisma.song.findMany({
          where:   { albumId: req.params.id, isActive: true },
          orderBy: { trackNumber: 'asc' },
        });
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
      }
    );

    if (!data) return res.status(404).json({ error: 'Album not found' });
    res.setHeader('X-Cache',       fromCache ? 'HIT' : 'MISS');
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
    invalidateAlbum(album.id);
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
    invalidateAlbum(req.params.id);
    res.json({ success: true, data: album });
  } catch (err) { next(err); }
});

// ── DELETE /api/albums/:id ───────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.album.update({ where: { id: req.params.id }, data: { isActive: false } });
    invalidateAlbum(req.params.id);
    res.json({ success: true, message: 'Album deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;
module.exports.invalidateAlbumCache = () => {
  listCache.flushAll();
  allWithSongCache.flushAll();
  detailCache.flushAll();
  songsCache.flushAll();
};