// routes/search.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ── GET /api/search?q=keyword ─────────────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const query = req.query.q?.toString().trim() || '';
    if (query.length < 2)
      return res.status(400).json({ error: 'Query must be at least 2 characters' });

    const term = { contains: query, mode: 'insensitive' };

    const [seriesList, albumList, episodeList, songList] = await Promise.all([
      prisma.series.findMany({
        where:   { isActive: true, title: term },
        include: { _count: { select: { episodes: true } } },
        take: 10,
      }),
      prisma.album.findMany({
        where:   { isActive: true, OR: [{ title: term }, { artist: term }] },
        include: { _count: { select: { songs: true } } },
        take: 10,
      }),
      prisma.episode.findMany({
        where:   { isActive: true, title: term },
        include: { series: { select: { id: true, title: true } } },
        take: 10,
      }),
      prisma.song.findMany({
        where:   { isActive: true, OR: [{ title: term }, { artist: term }] },
        include: { album: { select: { id: true, title: true } } },
        take: 10,
      }),
    ]);

    const [seriesWithCovers, albumsWithCovers] = await Promise.all([
      Promise.all(seriesList.map(async (s) => ({
        id:           s.id,
        type:         'series',
        title:        s.title,
        coverUrl:     await telegram.getCoverUrl(s.coverTelegramFileId),
        episodeCount: s._count.episodes,
      }))),
      Promise.all(albumList.map(async (a) => ({
        id:         a.id,
        type:       'album',
        title:      a.title,
        artist:     a.artist,
        coverUrl:   await telegram.getCoverUrl(a.coverTelegramFileId),
        trackCount: a._count.songs,
      }))),
    ]);

    res.json({
      success: true,
      data: {
        series:   seriesWithCovers,
        albums:   albumsWithCovers,
        episodes: episodeList.map((ep) => ({
          id:       ep.id,
          type:     'episode',
          title:    ep.title,
          seriesId: ep.seriesId,
          seriesTitle: ep.series.title,
        })),
        songs: songList.map((s) => ({
          id:         s.id,
          type:       'song',
          title:      s.title,
          artist:     s.artist,
          albumId:    s.albumId,
          albumTitle: s.album.title,
        })),
      },
    });
  } catch (err) { next(err); }
});

module.exports = router;