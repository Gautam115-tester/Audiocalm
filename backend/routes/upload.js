// routes/upload.js
// Admin route for uploading audio files and cover images to Telegram channels
// then saving the returned telegramFileId to the database

const express  = require('express');
const router   = express.Router();
const multer   = require('multer');
const fs       = require('fs');
const path     = require('path');
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// Store uploads temporarily on disk before sending to Telegram
const upload = multer({
  dest: '/tmp/audio_calm_uploads/',
  limits: { fileSize: 2 * 1024 * 1024 * 1024 }, // 2 GB max
});

// ── Helper: delete temp file after Telegram upload ────────────────────────────
function cleanupTemp(filePath) {
  try {
    if (filePath && fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
    }
  } catch (err) {
    console.warn('Temp file cleanup failed:', err.message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/episode-audio
// Upload a single episode audio file to the Stories Telegram channel
// Form fields: file (audio), seriesId, episodeNumber, title, duration (optional)
//
// Returns: { episodeId, telegramFileId, duration }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/episode-audio', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }

    const { seriesId, episodeNumber, title, duration } = req.body;

    if (!seriesId || !episodeNumber || !title) {
      return res.status(400).json({
        error: 'seriesId, episodeNumber and title are required',
      });
    }

    // Verify series exists
    const series = await prisma.series.findUnique({ where: { id: seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    console.log(`📤 Uploading episode audio to Telegram Stories channel...`);

    // Upload to Telegram Stories channel
    const result = await telegram.uploadAudio(
      tempPath,
      telegram.STORIES_CHANNEL_ID,
      `${series.title} - Ep ${episodeNumber}: ${title}`
    );

    // Save episode to database
    const episode = await prisma.episode.create({
      data: {
        seriesId,
        episodeNumber: parseInt(episodeNumber),
        title,
        telegramFileId: result.telegramFileId,
        duration: duration ? parseInt(duration) : result.duration || null,
        partCount: 1,
      },
    });

    console.log(`✅ Episode uploaded: ${episode.id}`);
    res.status(201).json({
      episodeId:      episode.id,
      telegramFileId: result.telegramFileId,
      duration:       episode.duration,
    });
  } catch (err) {
    console.error('POST /api/upload/episode-audio error:', err);
    res.status(500).json({ error: 'Upload failed', message: err.message });
  } finally {
    cleanupTemp(tempPath);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/song-audio
// Upload a single song audio file to the Music Telegram channel
// Form fields: file (audio), albumId, trackNumber, title, duration (optional)
//
// Returns: { songId, telegramFileId, duration }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/song-audio', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }

    const { albumId, trackNumber, title, duration } = req.body;

    if (!albumId || !trackNumber || !title) {
      return res.status(400).json({
        error: 'albumId, trackNumber and title are required',
      });
    }

    const album = await prisma.album.findUnique({ where: { id: albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    console.log(`📤 Uploading song audio to Telegram Music channel...`);

    const result = await telegram.uploadAudio(
      tempPath,
      telegram.MUSIC_CHANNEL_ID,
      `${album.title} - Track ${trackNumber}: ${title}`
    );

    const song = await prisma.song.create({
      data: {
        albumId,
        trackNumber: parseInt(trackNumber),
        title,
        telegramFileId: result.telegramFileId,
        duration: duration ? parseInt(duration) : result.duration || null,
        partCount: 1,
      },
    });

    console.log(`✅ Song uploaded: ${song.id}`);
    res.status(201).json({
      songId:         song.id,
      telegramFileId: result.telegramFileId,
      duration:       song.duration,
    });
  } catch (err) {
    console.error('POST /api/upload/song-audio error:', err);
    res.status(500).json({ error: 'Upload failed', message: err.message });
  } finally {
    cleanupTemp(tempPath);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/series-cover
// Upload cover image for a series to Telegram Covers channel
// Form fields: file (image), seriesId
//
// Returns: { seriesId, coverUrl }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/series-cover', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }

    const { seriesId } = req.body;
    if (!seriesId) return res.status(400).json({ error: 'seriesId is required' });

    const series = await prisma.series.findUnique({ where: { id: seriesId } });
    if (!series) return res.status(404).json({ error: 'Series not found' });

    console.log(`📤 Uploading series cover to Telegram Covers channel...`);

    const result = await telegram.uploadPhoto(
      tempPath,
      telegram.COVERS_CHANNEL_ID,
      `Cover: ${series.title}`
    );

    // Save the telegramFileId on the series record
    await prisma.series.update({
      where: { id: seriesId },
      data: { coverTelegramFileId: result.telegramFileId },
    });

    // Return the live URL so Flutter can display it immediately
    const coverUrl = await telegram.getCoverUrl(result.telegramFileId);

    console.log(`✅ Series cover uploaded for: ${series.title}`);
    res.json({ seriesId, coverUrl });
  } catch (err) {
    console.error('POST /api/upload/series-cover error:', err);
    res.status(500).json({ error: 'Cover upload failed', message: err.message });
  } finally {
    cleanupTemp(tempPath);
  }
});

router.use((req, res, next) => {
  const key = req.headers['x-api-key'];
  if (key !== process.env.API_SECRET_KEY) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/album-cover
// Upload cover image for an album to Telegram Covers channel
// Form fields: file (image), albumId
//
// Returns: { albumId, coverUrl }
// ─────────────────────────────────────────────────────────────────────────────
router.post('/album-cover', upload.single('file'), async (req, res) => {
  const tempPath = req.file?.path;
  try {
    if (!req.file) {
      return res.status(400).json({ error: 'No file uploaded' });
    }

    const { albumId } = req.body;
    if (!albumId) return res.status(400).json({ error: 'albumId is required' });

    const album = await prisma.album.findUnique({ where: { id: albumId } });
    if (!album) return res.status(404).json({ error: 'Album not found' });

    console.log(`📤 Uploading album cover to Telegram Covers channel...`);

    const result = await telegram.uploadPhoto(
      tempPath,
      telegram.COVERS_CHANNEL_ID,
      `Cover: ${album.title}`
    );

    await prisma.album.update({
      where: { id: albumId },
      data: { coverTelegramFileId: result.telegramFileId },
    });

    const coverUrl = await telegram.getCoverUrl(result.telegramFileId);

    console.log(`✅ Album cover uploaded for: ${album.title}`);
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
// Upload a large episode split into multiple parts
// Form fields: files[] (multiple audio files), seriesId, episodeNumber, title
//
// Returns: { episodeId, partCount, telegramFileIds[] }
// ─────────────────────────────────────────────────────────────────────────────
router.post(
  '/episode-audio-multipart',
  upload.array('files', 10),
  async (req, res) => {
    const tempPaths = req.files?.map((f) => f.path) || [];
    try {
      if (!req.files || req.files.length === 0) {
        return res.status(400).json({ error: 'No files uploaded' });
      }

      const { seriesId, episodeNumber, title, duration } = req.body;

      if (!seriesId || !episodeNumber || !title) {
        return res.status(400).json({
          error: 'seriesId, episodeNumber and title are required',
        });
      }

      const series = await prisma.series.findUnique({ where: { id: seriesId } });
      if (!series) return res.status(404).json({ error: 'Series not found' });

      console.log(`📤 Uploading ${req.files.length} episode parts to Telegram...`);

      // Upload all parts to Telegram sequentially
      const telegramFileIds = [];
      for (let i = 0; i < req.files.length; i++) {
        const result = await telegram.uploadAudio(
          req.files[i].path,
          telegram.STORIES_CHANNEL_ID,
          `${series.title} - Ep ${episodeNumber}: ${title} (Part ${i + 1}/${req.files.length})`
        );
        telegramFileIds.push(result.telegramFileId);
        console.log(`  ✅ Part ${i + 1}/${req.files.length} uploaded`);
      }

      // Store as JSON array in telegramFileId column
      const episode = await prisma.episode.create({
        data: {
          seriesId,
          episodeNumber: parseInt(episodeNumber),
          title,
          telegramFileId: JSON.stringify(telegramFileIds),
          duration: duration ? parseInt(duration) : null,
          partCount: telegramFileIds.length,
        },
      });

      console.log(`✅ Multi-part episode created: ${episode.id}`);
      res.status(201).json({
        episodeId:       episode.id,
        partCount:       episode.partCount,
        telegramFileIds,
      });
    } catch (err) {
      console.error('POST /api/upload/episode-audio-multipart error:', err);
      res.status(500).json({ error: 'Multi-part upload failed', message: err.message });
    } finally {
      tempPaths.forEach(cleanupTemp);
    }
  }
);

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/upload/song-audio-multipart
// Same as above but for songs
// ─────────────────────────────────────────────────────────────────────────────
router.post(
  '/song-audio-multipart',
  upload.array('files', 10),
  async (req, res) => {
    const tempPaths = req.files?.map((f) => f.path) || [];
    try {
      if (!req.files || req.files.length === 0) {
        return res.status(400).json({ error: 'No files uploaded' });
      }

      const { albumId, trackNumber, title, duration } = req.body;

      if (!albumId || !trackNumber || !title) {
        return res.status(400).json({
          error: 'albumId, trackNumber and title are required',
        });
      }

      const album = await prisma.album.findUnique({ where: { id: albumId } });
      if (!album) return res.status(404).json({ error: 'Album not found' });

      console.log(`📤 Uploading ${req.files.length} song parts to Telegram...`);

      const telegramFileIds = [];
      for (let i = 0; i < req.files.length; i++) {
        const result = await telegram.uploadAudio(
          req.files[i].path,
          telegram.MUSIC_CHANNEL_ID,
          `${album.title} - Track ${trackNumber}: ${title} (Part ${i + 1}/${req.files.length})`
        );
        telegramFileIds.push(result.telegramFileId);
        console.log(`  ✅ Part ${i + 1}/${req.files.length} uploaded`);
      }

      const song = await prisma.song.create({
        data: {
          albumId,
          trackNumber: parseInt(trackNumber),
          title,
          telegramFileId: JSON.stringify(telegramFileIds),
          duration: duration ? parseInt(duration) : null,
          partCount: telegramFileIds.length,
        },
      });

      console.log(`✅ Multi-part song created: ${song.id}`);
      res.status(201).json({
        songId:          song.id,
        partCount:       song.partCount,
        telegramFileIds,
      });
    } catch (err) {
      console.error('POST /api/upload/song-audio-multipart error:', err);
      res.status(500).json({ error: 'Multi-part upload failed', message: err.message });
    } finally {
      tempPaths.forEach(cleanupTemp);
    }
  }
);

module.exports = router;
