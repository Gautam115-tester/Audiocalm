// routes/sync.js
const express  = require('express');
const router   = express.Router();
const axios    = require('axios');
const prisma   = require('../services/db');

// ── CORS for local HTML dashboard ─────────────────────────────────────────────
router.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, x-api-key');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

// ── Helper: get all updates from a channel since last sync ───────────────────
async function fetchUpdates(offset = 0) {
  const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
    params: { offset, limit: 100, timeout: 0 },
  });
  return res.data.result || [];
}

// ── Helper: Clean Album Name ──────────────────────────────────────────────────
// This ensures "Befikra", "Befikra 2", and "Befikra (OST)" are handled perfectly
function extractAndCleanAlbumName(fileName, performer) {
  if (!fileName) return performer || 'Unknown';

  // 1. Lazy match regex: Stops capturing at "Original", "OST", "TR", or file extension
  const albumMatch = fileName.match(/^(.+?)(?:[\s_(\[-]*(?:Original|OST|Soundtrack|TR\d)|\.[a-z0-9]{3,4}$|$)/i);
  
  let albumName = albumMatch && albumMatch[1] ? albumMatch[1] : performer;

  // 2. Clean up the extracted name (replace underscores with spaces)
  albumName = albumName.replace(/[_\-\.]+/g, ' ');

  // 3. Remove any lingering parentheses (e.g., if it was just "Befikra (Reprise)")
  albumName = albumName.replace(/\([^)]*\)/g, '');

  // 4. Trim extra spaces and title-case it for clean DB storage
  albumName = albumName.replace(/\s+/g, ' ').trim();
  albumName = albumName.toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());

  return albumName || 'Unknown Album';
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

      // Use our new robust helper to get the exact album name
      const albumName = extractAndCleanAlbumName(audio.file_name, performer);

      // Find or create album in Supabase via Prisma
      let album = await prisma.album.findFirst({
        where: { title: { equals: albumName, mode: 'insensitive' } },
      });

      if (!album) {
        album = await prisma.album.create({
          data: { title: albumName, artist: performer },
        });
        console.log(`✅ Created new album: ${albumName}`);
      }

      // Skip if song with this fileId already exists (Prevents duplicates)
      const existing = await prisma.song.findFirst({
        where: { telegramFileId: fileId },
      });
      
      if (existing) { 
        skipped++; 
        continue; 
      }

      // Create song linked to the correct album
      // We calculate trackNumber fallback accurately based on current DB count
      const fallbackTrackNum = (await prisma.song.count({ where: { albumId: album.id } })) + 1;

      await prisma.song.create({
        data: {
          albumId:        album.id,
          trackNumber:    trackNumber || fallbackTrackNum,
          title:          title,
          telegramFileId: fileId,
          duration:       duration,
          partCount:      1,
        },
      });

      created++;
      console.log(`🎵 Saved: ${title} -> Album: ${albumName}`);
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

      // Parse caption
      const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
      const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

      if (albumMatch) {
        // Clean the caption name just like we clean the audio filenames
        // so "COVER_ALBUM:Befikre (Original Motion Picture Soundtrack)" matches "Befikre"
        let name = albumMatch[1].replace(/\([^)]*\)/g, '').trim();
        
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
        let name = seriesMatch[1].replace(/\([^)]*\)/g, '').trim();
        
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
