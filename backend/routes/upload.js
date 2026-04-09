// routes/upload.js
// Admin routes for uploading audio files and cover images to Telegram.
// ALL routes are protected by x-api-key (auth middleware applied in server.js).

const express  = require('express');
const router   = express.Router();
const multer   = require('multer');
const fs       = require('fs');
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

const upload = multer({
  dest:   '/tmp/audiocalm_uploads/',
  limits: { fileSize: 2 * 1024 * 1024 * 1024 }, // 2 GB
});

function cleanup(...paths) {
  for (const p of paths) {
    try { if (p && fs.existsSync(p)) fs.unlinkSync(p); } catch { /* ignore */ }
  }
}

// ── POST /api/upload/episode-audio ───────────────────────────────────────────
router.post('/episode-audio', upload.single('file'), async (req, res, next) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file)
      return res.status(400).json({ error: 'No file uploaded' });

    const { seriesId, episodeNumber, title, description, duration } = req.body;
    if (!seriesId || !episodeNumber || !title)
      return res.status(400).json({ error: 'seriesId, episodeNumber and title are required' });

    const series = await prisma.series.findUnique({ where: { id: seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    const result = await telegram.uploadAudio(
      tempPath, telegram.STORIES_CHANNEL_ID,
      `${series.title} — EP${episodeNumber}: ${title}`
    );

    const episode = await prisma.episode.create({
      data: {
        seriesId,
        episodeNumber: parseInt(episodeNumber),
        title,
        description: description || null,
        telegramFileId: result.telegramFileId,
        duration:  duration ? parseInt(duration) : result.duration || null,
        partCount: 1,
      },
    });

    res.status(201).json({ success: true, data: { episodeId: episode.id, duration: episode.duration } });
  } catch (err) { next(err); }
  finally { cleanup(tempPath); }
});

// ── POST /api/upload/episode-audio-multipart ─────────────────────────────────
router.post('/episode-audio-multipart', upload.array('files', 10), async (req, res, next) => {
  const tempPaths = req.files?.map((f) => f.path) || [];
  try {
    if (!req.files?.length)
      return res.status(400).json({ error: 'No files uploaded' });

    const { seriesId, episodeNumber, title, description, duration } = req.body;
    if (!seriesId || !episodeNumber || !title)
      return res.status(400).json({ error: 'seriesId, episodeNumber and title are required' });

    const series = await prisma.series.findUnique({ where: { id: seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    const telegramFileIds = [];
    for (let i = 0; i < req.files.length; i++) {
      const result = await telegram.uploadAudio(
        req.files[i].path, telegram.STORIES_CHANNEL_ID,
        `${series.title} — EP${episodeNumber}: ${title} (Part ${i + 1}/${req.files.length})`
      );
      telegramFileIds.push(result.telegramFileId);
    }

    const episode = await prisma.episode.create({
      data: {
        seriesId,
        episodeNumber: parseInt(episodeNumber),
        title,
        description:   description || null,
        telegramFileId: JSON.stringify(telegramFileIds),
        duration:  duration ? parseInt(duration) : null,
        partCount: telegramFileIds.length,
      },
    });

    res.status(201).json({
      success: true,
      data: { episodeId: episode.id, partCount: episode.partCount },
    });
  } catch (err) { next(err); }
  finally { tempPaths.forEach(cleanup); }
});

// ── POST /api/upload/song-audio ──────────────────────────────────────────────
router.post('/song-audio', upload.single('file'), async (req, res, next) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file)
      return res.status(400).json({ error: 'No file uploaded' });

    const { albumId, trackNumber, title, artist, duration } = req.body;
    if (!albumId || !trackNumber || !title)
      return res.status(400).json({ error: 'albumId, trackNumber and title are required' });

    const album = await prisma.album.findUnique({ where: { id: albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    const result = await telegram.uploadAudio(
      tempPath, telegram.MUSIC_CHANNEL_ID,
      `${album.title} — TR${trackNumber}: ${title}`
    );

    const song = await prisma.song.create({
      data: {
        albumId,
        trackNumber: parseInt(trackNumber),
        title,
        artist:         artist         || null,
        telegramFileId: result.telegramFileId,
        duration:  duration ? parseInt(duration) : result.duration || null,
        partCount: 1,
      },
    });

    res.status(201).json({ success: true, data: { songId: song.id, duration: song.duration } });
  } catch (err) { next(err); }
  finally { cleanup(tempPath); }
});

// ── POST /api/upload/song-audio-multipart ────────────────────────────────────
router.post('/song-audio-multipart', upload.array('files', 10), async (req, res, next) => {
  const tempPaths = req.files?.map((f) => f.path) || [];
  try {
    if (!req.files?.length)
      return res.status(400).json({ error: 'No files uploaded' });

    const { albumId, trackNumber, title, artist, duration } = req.body;
    if (!albumId || !trackNumber || !title)
      return res.status(400).json({ error: 'albumId, trackNumber and title are required' });

    const album = await prisma.album.findUnique({ where: { id: albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    const telegramFileIds = [];
    for (let i = 0; i < req.files.length; i++) {
      const result = await telegram.uploadAudio(
        req.files[i].path, telegram.MUSIC_CHANNEL_ID,
        `${album.title} — TR${trackNumber}: ${title} (Part ${i + 1}/${req.files.length})`
      );
      telegramFileIds.push(result.telegramFileId);
    }

    const song = await prisma.song.create({
      data: {
        albumId,
        trackNumber: parseInt(trackNumber),
        title,
        artist:        artist || null,
        telegramFileId: JSON.stringify(telegramFileIds),
        duration:  duration ? parseInt(duration) : null,
        partCount: telegramFileIds.length,
      },
    });

    res.status(201).json({
      success: true,
      data: { songId: song.id, partCount: song.partCount },
    });
  } catch (err) { next(err); }
  finally { tempPaths.forEach(cleanup); }
});

// ── POST /api/upload/series-cover ────────────────────────────────────────────
router.post('/series-cover', upload.single('file'), async (req, res, next) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file)        return res.status(400).json({ error: 'No file uploaded' });
    if (!req.body.seriesId) return res.status(400).json({ error: 'seriesId is required' });

    const series = await prisma.series.findUnique({ where: { id: req.body.seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    const result = await telegram.uploadPhoto(
      tempPath, telegram.COVERS_CHANNEL_ID, `COVER_SERIES:${series.title}`
    );

    await prisma.series.update({
      where: { id: series.id },
      data:  { coverTelegramFileId: result.telegramFileId },
    });

    const coverUrl = await telegram.getCoverUrl(result.telegramFileId);
    res.json({ success: true, data: { seriesId: series.id, coverUrl } });
  } catch (err) { next(err); }
  finally { cleanup(tempPath); }
});

// ── POST /api/upload/album-cover ─────────────────────────────────────────────
router.post('/album-cover', upload.single('file'), async (req, res, next) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file)       return res.status(400).json({ error: 'No file uploaded' });
    if (!req.body.albumId) return res.status(400).json({ error: 'albumId is required' });

    const album = await prisma.album.findUnique({ where: { id: req.body.albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    const result = await telegram.uploadPhoto(
      tempPath, telegram.COVERS_CHANNEL_ID, `COVER_ALBUM:${album.title}`
    );

    await prisma.album.update({
      where: { id: album.id },
      data:  { coverTelegramFileId: result.telegramFileId },
    });

    const coverUrl = await telegram.getCoverUrl(result.telegramFileId);
    res.json({ success: true, data: { albumId: album.id, coverUrl } });
  } catch (err) { next(err); }
  finally { cleanup(tempPath); }
});

module.exports = router;