// routes/albums.js
//
// PERFORMANCE FIXES IN THIS VERSION
// ==================================
//
// 1. GET /api/albums/all-with-songs now fires warmUrlsBackground() after
//    building the response — resolves CDN URLs for the first track of each
//    album BEFORE the user taps play. This eliminates the 200–800ms cold
//    Telegram getFile delay on first playback.
//
// 2. All other existing fixes preserved (cache stampede prevention,
//    server-side NodeCache, cache invalidation on mutations).

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

// ── Background URL pre-warmer ─────────────────────────────────────────────────
// Resolves the first track's Telegram CDN URL for each album so it's cached
// before the user taps play. Completely non-blocking — fire and forget.
function preWarmFirstTrackUrls(albums) {
  try {
    const fileIds = [];

    for (const album of albums) {
      if (!album.songs || album.songs.length === 0) continue;
      const firstSong = album.songs[0];
      const raw = firstSong._telegramFileId; // stored temporarily below
      if (!raw) continue;

      if (raw.startsWith('[')) {
        try {
          const parts = JSON.parse(raw);
          if (parts[0]) fileIds.push(parts[0]);
        } catch (_) {}
      } else {
        fileIds.push(raw);
      }

      // Stop after 8 albums — enough to cover the visible screen
      if (fileIds.length >= 8) break;
    }

    if (fileIds.length > 0) {
      telegram.warmUrlsBackground(fileIds);
    }
  } catch (_) {
    // Non-fatal — pre-warming is best-effort
  }
}

// ── GET /api/albums/all-with-songs ───────────────────────────────────────────
// PRIMARY: single endpoint replaces 23 parallel startup requests.
// Flutter calls this ONCE and gets everything it needs.
// After responding, fires background URL pre-warm for instant playback.
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
            // Temporarily store first song fileId for pre-warming (stripped before response)
            _firstTrackFileId: album.songs[0]?.telegramFileId || null,
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

    // Strip internal _firstTrackFileId before sending to client
    const clientData = data.map(({ _firstTrackFileId, ...album }) => album);
    res.json({ success: true, data: clientData });

    // Fire background pre-warm AFTER responding (non-blocking)
    if (!fromCache) {
      const fileIds = data
        .map(a => {
          const raw = a._firstTrackFileId;
          if (!raw) return null;
          if (raw.startsWith('[')) {
            try { return JSON.parse(raw)[0]; } catch { return null; }
          }
          return raw;
        })
        .filter(Boolean)
        .slice(0, 8);

      if (fileIds.length > 0) {
        telegram.warmUrlsBackground(fileIds);
      }
    }
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