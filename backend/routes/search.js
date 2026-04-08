// routes/search.js
const express = require('express');
const router  = express.Router();
const prisma  = require('../services/db');
const telegram = require('../services/telegram');

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/search?q=keyword
// Full-text search across series, albums, episodes, songs
// Used by Flutter SearchScreen
// ─────────────────────────────────────────────────────────────────────────────
router.get('/', async (req, res) => {
  try {
    const query = req.query.q?.toString().trim();

    if (!query || query.length < 2) {
      return res.status(400).json({ error: 'Query must be at least 2 characters' });
    }

    const searchTerm = query.toLowerCase();

    // Run all searches in parallel
    const [series, albums, episodes, songs] = await Promise.all([

      prisma.series.findMany({
        where: {
          isActive: true,
          title: { contains: searchTerm, mode: 'insensitive' },
        },
        include: { _count: { select: { episodes: true } } },
        take: 10,
      }),

      prisma.album.findMany({
        where: {
          isActive: true,
          OR: [
            { title:  { contains: searchTerm, mode: 'insensitive' } },
            { artist: { contains: searchTerm, mode: 'insensitive' } },
          ],
        },
        include: { _count: { select: { songs: true } } },
        take: 10,
      }),

      prisma.episode.findMany({
        where: {
          isActive: true,
          title: { contains: searchTerm, mode: 'insensitive' },
        },
        take: 10,
      }),

      prisma.song.findMany({
        where: {
          isActive: true,
          title: { contains: searchTerm, mode: 'insensitive' },
        },
        take: 10,
      }),

    ]);

    // Attach cover URLs to series and albums
    const seriesWithCovers = await Promise.all(
      series.map(async (s) => ({
        id:           s.id,
        title:        s.title,
        coverUrl:     await telegram.getCoverUrl(s.coverTelegramFileId),
        episodeCount: s._count.episodes,
      }))
    );

    const albumsWithCovers = await Promise.all(
      albums.map(async (a) => ({
        id:         a.id,
        title:      a.title,
        artist:     a.artist,
        coverUrl:   await telegram.getCoverUrl(a.coverTelegramFileId),
        trackCount: a._count.songs,
      }))
    );

    res.json({
      series:   seriesWithCovers,
      albums:   albumsWithCovers,
      episodes: episodes.map((ep) => ({
        id:       ep.id,
        title:    ep.title,
        seriesId: ep.seriesId,
      })),
      songs: songs.map((s) => ({
        id:      s.id,
        title:   s.title,
        albumId: s.albumId,
      })),
    });
  } catch (err) {
    console.error('GET /api/search error:', err);
    res.status(500).json({ error: 'Search failed' });
  }
});

module.exports = router;
