// routes/sync.js
const express  = require('express');
const router   = express.Router();
const axios    = require('axios');
const prisma   = require('../services/db');

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

// ── Helper: get all updates from a channel since last sync ───────────────────
async function fetchUpdates(offset = 0) {
  const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
    params: { offset, limit: 100, timeout: 0 },
  });
  return res.data.result || [];
}

// ── POST /api/sync/music
// Reads Music Telegram channel and saves songs to DB
// Requires album to already exist — matches by caption or creates one
// ─────────────────────────────────────────────────────────────────────────────
router.post('/music', async (req, res) => {
  try {
    const updates = await fetchUpdates();
    let created = 0;
    let skipped = 0;

    for (const update of updates) {
      const post = update.channel_post;
      if (!post) continue;

      // Only process Music channel posts
      if (String(post.chat.id) !== String(process.env.TELEGRAM_MUSIC_CHANNEL_ID)) continue;

      const audio = post.audio;
      if (!audio) continue;

      const title     = audio.title || audio.file_name || 'Unknown';
      const performer = audio.performer || 'Unknown';
      const fileId    = audio.file_id;
      const duration  = audio.duration;

      // Extract track number from filename e.g. TR02 → 2
      const trackMatch = audio.file_name?.match(/TR(\d+)/i);
      const trackNumber = trackMatch ? parseInt(trackMatch[1]) : null;

      // Extract album name from filename e.g. Befikre_Original...TR02...
      const albumMatch = audio.file_name?.match(/^([^_]+(?:_[^_]+)*?)_(?:Original|TR\d)/i);
      const albumName = albumMatch
        ? albumMatch[1].replace(/_/g, ' ').trim()
        : performer;

      // Find or create album
      let album = await prisma.album.findFirst({
        where: { title: { contains: albumName, mode: 'insensitive' } },
      });

      if (!album) {
        album = await prisma.album.create({
          data: { title: albumName, artist: performer },
        });
        console.log(`✅ Created album: ${albumName}`);
      }

      // Skip if song with this fileId already exists
      const existing = await prisma.song.findFirst({
        where: { telegramFileId: fileId },
      });
      if (existing) { skipped++; continue; }

      // Create song
      await prisma.song.create({
        data: {
          albumId:        album.id,
          trackNumber:    trackNumber || (await prisma.song.count({ where: { albumId: album.id } })) + 1,
          title,
          telegramFileId: fileId,
          duration,
          partCount:      1,
        },
      });

      created++;
      console.log(`🎵 Saved: ${title}`);
    }

    res.json({ message: 'Music sync complete', created, skipped });
  } catch (err) {
    console.error('Sync error:', err.message);
    res.status(500).json({ error: 'Sync failed', message: err.message });
  }
});

// ── POST /api/sync/covers
// Reads Covers channel and links cover photos to albums/series by caption
// Caption format: COVER_ALBUM:Befikre  or  COVER_SERIES:Deep Sleep
// ─────────────────────────────────────────────────────────────────────────────
router.post('/covers', async (req, res) => {
  try {
    const updates = await fetchUpdates();
    let updated = 0;

    for (const update of updates) {
      const post = update.channel_post;
      if (!post) continue;

      if (String(post.chat.id) !== String(process.env.TELEGRAM_COVERS_CHANNEL_ID)) continue;

      const caption = post.caption || '';
      const photos  = post.photo;
      if (!photos || photos.length === 0) continue;

      // Best resolution photo
      const bestPhoto = photos[photos.length - 1];
      const fileId    = bestPhoto.file_id;

      // Parse caption: COVER_ALBUM:Befikre
      const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
      const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

      if (albumMatch) {
        const name = albumMatch[1].trim();
        const album = await prisma.album.findFirst({
          where: { title: { contains: name, mode: 'insensitive' } },
        });
        if (album) {
          await prisma.album.update({
            where: { id: album.id },
            data:  { coverTelegramFileId: fileId },
          });
          console.log(`🖼️ Cover set for album: ${album.title}`);
          updated++;
        }
      }

      if (seriesMatch) {
        const name = seriesMatch[1].trim();
        const series = await prisma.series.findFirst({
          where: { title: { contains: name, mode: 'insensitive' } },
        });
        if (series) {
          await prisma.series.update({
            where: { id: series.id },
            data:  { coverTelegramFileId: fileId },
          });
          console.log(`🖼️ Cover set for series: ${series.title}`);
          updated++;
        }
      }
    }

    res.json({ message: 'Covers sync complete', updated });
  } catch (err) {
    console.error('Covers sync error:', err.message);
    res.status(500).json({ error: 'Covers sync failed', message: err.message });
  }
});

module.exports = router;