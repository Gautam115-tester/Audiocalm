// routes/upload.js
// Admin route for uploading audio files and cover images to Telegram channels.

const express  = require('express');
const router   = express.Router();
const multer   = require('multer');
const fs       = require('fs');
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ─────────────────────────────────────────────────────────────────────────────
// AUTH — must come FIRST, before any route definitions.
// BUG FIX: original code placed this middleware AFTER the routes, meaning
// /episode-audio, /song-audio, /series-cover were publicly accessible.
// ─────────────────────────────────────────────────────────────────────────────
router.use((req, res, next) => {
  const key = req.headers['x-api-key'];
  if (!key || key !== process.env.API_SECRET_KEY) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
});

// Store uploads temporarily before sending to Telegram
const upload = multer({
  dest: '/tmp/audio_calm_uploads/',
  limits: { fileSize: 2 * 1024 * 1024 * 1024 }, // 2 GB
});

function cleanupTemp(filePath) {
  try {
    if (filePath && fs.existsSync(filePath)) fs.unlinkSync(filePath);
  } catch (err) {
    console.warn('Temp file cleanup failed:', err.message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/episode-audio
// ─────────────────────────────────────────────────────────────────────────────
router.post('/episode-audio', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

    const { seriesId, episodeNumber, title, duration } = req.body;
    if (!seriesId || !episodeNumber || !title)
      return res.status(400).json({ error: 'seriesId, episodeNumber and title are required' });

    const series = await prisma.series.findUnique({ where: { id: seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    console.log(`📤 Uploading episode audio…`);
    const result = await telegram.uploadAudio(
      tempPath, telegram.STORIES_CHANNEL_ID,
      `${series.title} - Ep ${episodeNumber}: ${title}`
    );

    const episode = await prisma.episode.create({
      data: {
        seriesId, episodeNumber: parseInt(episodeNumber), title,
        telegramFileId: result.telegramFileId,
        duration: duration ? parseInt(duration) : result.duration || null,
        partCount: 1,
      },
    });

    console.log(`✅ Episode uploaded: ${episode.id}`);
    res.status(201).json({ episodeId: episode.id, telegramFileId: result.telegramFileId, duration: episode.duration });
  } catch (err) {
    console.error('POST /api/upload/episode-audio error:', err);
    res.status(500).json({ error: 'Upload failed', message: err.message });
  } finally {
    cleanupTemp(tempPath);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/song-audio
// ─────────────────────────────────────────────────────────────────────────────
router.post('/song-audio', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

    const { albumId, trackNumber, title, duration } = req.body;
    if (!albumId || !trackNumber || !title)
      return res.status(400).json({ error: 'albumId, trackNumber and title are required' });

    const album = await prisma.album.findUnique({ where: { id: albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    console.log(`📤 Uploading song audio…`);
    const result = await telegram.uploadAudio(
      tempPath, telegram.MUSIC_CHANNEL_ID,
      `${album.title} - Track ${trackNumber}: ${title}`
    );

    const song = await prisma.song.create({
      data: {
        albumId, trackNumber: parseInt(trackNumber), title,
        telegramFileId: result.telegramFileId,
        duration: duration ? parseInt(duration) : result.duration || null,
        partCount: 1,
      },
    });

    console.log(`✅ Song uploaded: ${song.id}`);
    res.status(201).json({ songId: song.id, telegramFileId: result.telegramFileId, duration: song.duration });
  } catch (err) {
    console.error('POST /api/upload/song-audio error:', err);
    res.status(500).json({ error: 'Upload failed', message: err.message });
  } finally {
    cleanupTemp(tempPath);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/series-cover
// ─────────────────────────────────────────────────────────────────────────────
router.post('/series-cover', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

    const { seriesId } = req.body;
    if (!seriesId) return res.status(400).json({ error: 'seriesId is required' });

    const series = await prisma.series.findUnique({ where: { id: seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    console.log(`📤 Uploading series cover…`);
    const result = await telegram.uploadPhoto(tempPath, telegram.COVERS_CHANNEL_ID, `Cover: ${series.title}`);

    await prisma.series.update({ where: { id: seriesId }, data: { coverTelegramFileId: result.telegramFileId } });
    const coverUrl = await telegram.getCoverUrl(result.telegramFileId);

    console.log(`✅ Series cover uploaded: ${series.title}`);
    res.json({ seriesId, coverUrl });
  } catch (err) {
    console.error('POST /api/upload/series-cover error:', err);
    res.status(500).json({ error: 'Cover upload failed', message: err.message });
  } finally {
    cleanupTemp(tempPath);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/album-cover
// ─────────────────────────────────────────────────────────────────────────────
router.post('/album-cover', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

    const { albumId } = req.body;
    if (!albumId) return res.status(400).json({ error: 'albumId is required' });

    const album = await prisma.album.findUnique({ where: { id: albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    console.log(`📤 Uploading album cover…`);
    const result = await telegram.uploadPhoto(tempPath, telegram.COVERS_CHANNEL_ID, `Cover: ${album.title}`);

    await prisma.album.update({ where: { id: albumId }, data: { coverTelegramFileId: result.telegramFileId } });
    const coverUrl = await telegram.getCoverUrl(result.telegramFileId);

    console.log(`✅ Album cover uploaded: ${album.title}`);
    res.json({ albumId, coverUrl });
  } catch (err) {
    console.error('POST /api/upload/album-cover error:', err);
    res.status(500).json({ error: 'Cover upload failed', message: err.message });
  } finally {
    cleanupTemp(tempPath);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/episode-audio-multipart
// ─────────────────────────────────────────────────────────────────────────────
router.post('/episode-audio-multipart', upload.array('files', 10), async (req, res) => {
  const tempPaths = req.files?.map(f => f.path) || [];
  try {
    if (!req.files?.length) return res.status(400).json({ error: 'No files uploaded' });

    const { seriesId, episodeNumber, title, duration } = req.body;
    if (!seriesId || !episodeNumber || !title)
      return res.status(400).json({ error: 'seriesId, episodeNumber and title are required' });

    const series = await prisma.series.findUnique({ where: { id: seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    console.log(`📤 Uploading ${req.files.length} episode parts…`);
    const telegramFileIds = [];
    for (let i = 0; i < req.files.length; i++) {
      const result = await telegram.uploadAudio(
        req.files[i].path, telegram.STORIES_CHANNEL_ID,
        `${series.title} - Ep ${episodeNumber}: ${title} (Part ${i + 1}/${req.files.length})`
      );
      telegramFileIds.push(result.telegramFileId);
      console.log(`  ✅ Part ${i + 1}/${req.files.length}`);
    }

    const episode = await prisma.episode.create({
      data: {
        seriesId, episodeNumber: parseInt(episodeNumber), title,
        telegramFileId: JSON.stringify(telegramFileIds),
        duration: duration ? parseInt(duration) : null,
        partCount: telegramFileIds.length,
      },
    });

    console.log(`✅ Multi-part episode: ${episode.id}`);
    res.status(201).json({ episodeId: episode.id, partCount: episode.partCount, telegramFileIds });
  } catch (err) {
    console.error('POST /api/upload/episode-audio-multipart error:', err);
    res.status(500).json({ error: 'Multi-part upload failed', message: err.message });
  } finally {
    tempPaths.forEach(cleanupTemp);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/song-audio-multipart
// ─────────────────────────────────────────────────────────────────────────────
router.post('/song-audio-multipart', upload.array('files', 10), async (req, res) => {
  const tempPaths = req.files?.map(f => f.path) || [];
  try {
    if (!req.files?.length) return res.status(400).json({ error: 'No files uploaded' });

    const { albumId, trackNumber, title, duration } = req.body;
    if (!albumId || !trackNumber || !title)
      return res.status(400).json({ error: 'albumId, trackNumber and title are required' });

    const album = await prisma.album.findUnique({ where: { id: albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    console.log(`📤 Uploading ${req.files.length} song parts…`);
    const telegramFileIds = [];
    for (let i = 0; i < req.files.length; i++) {
      const result = await telegram.uploadAudio(
        req.files[i].path, telegram.MUSIC_CHANNEL_ID,
        `${album.title} - Track ${trackNumber}: ${title} (Part ${i + 1}/${req.files.length})`
      );
      telegramFileIds.push(result.telegramFileId);
      console.log(`  ✅ Part ${i + 1}/${req.files.length}`);
    }

    const song = await prisma.song.create({
      data: {
        albumId, trackNumber: parseInt(trackNumber), title,
        telegramFileId: JSON.stringify(telegramFileIds),
        duration: duration ? parseInt(duration) : null,
        partCount: telegramFileIds.length,
      },
    });

    console.log(`✅ Multi-part song: ${song.id}`);
    res.status(201).json({ songId: song.id, partCount: song.partCount, telegramFileIds });
  } catch (err) {
    console.error('POST /api/upload/song-audio-multipart error:', err);
    res.status(500).json({ error: 'Multi-part upload failed', message: err.message });
  } finally {
    tempPaths.forEach(cleanupTemp);
  }
});

module.exports = router;