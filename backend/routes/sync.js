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

// ── Helper: get all updates from a channel ───────────────────────────────────
async function fetchUpdates(offset = 0) {
  const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
    params: { offset, limit: 100, timeout: 0 },
  });
  return res.data.result || [];
}

// ── Helper: normalize album name for duplicate detection ──────────────────────
// Strips "(Original Motion Picture Soundtrack)", "(OST)", etc.
// so "Befikre" and "Befikre (Original Motion Picture Soundtrack)" match.
function normalizeAlbumName(name) {
  return name
    .replace(/\s*\(original\s+(motion\s+picture\s+)?soundtrack\)/gi, '')
    .replace(/\s*\(ost\)/gi, '')
    .replace(/\s*\(deluxe(\s+edition)?\)/gi, '')
    .replace(/\s*\(remastered(\s+\d{4})?\)/gi, '')
    .replace(/_/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

// ── Helper: find existing album by normalized name ────────────────────────────
async function findAlbumByNormalizedName(rawName) {
  const normalized = normalizeAlbumName(rawName);
  const all = await prisma.album.findMany({ where: { isActive: true } });
  return all.find(a => normalizeAlbumName(a.title) === normalized) || null;
}

// ── POST /api/sync/music ──────────────────────────────────────────────────────
// Reads Music Telegram channel and saves songs to DB.
// Uses normalized album name matching to prevent duplicate albums.
router.post('/music', async (req, res) => {
  try {
    const updates = await fetchUpdates();
    let created = 0;
    let skipped = 0;

    for (const update of updates) {
      const post = update.channel_post;
      if (!post) continue;

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

      // Extract raw album name from filename prefix before "Original" or "TR\d" or "OST"
      // e.g. "Befikre_Original_Motion_Picture_Soundtrack_TR02_Ude_Dil_Befikre"
      //   → rawAlbumName = "Befikre"
      const albumMatch = audio.file_name?.match(/^([A-Za-z0-9_]+?)_(?:Original|TR\d|OST)/i);
      const rawAlbumName = albumMatch
        ? albumMatch[1].replace(/_/g, ' ').trim()
        : performer;

      // Find album using normalized comparison to avoid duplicates
      let album = await findAlbumByNormalizedName(rawAlbumName);

      if (!album) {
        // Title-case the clean name for display
        const cleanName = rawAlbumName
          .split(' ')
          .map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
          .join(' ');

        album = await prisma.album.create({
          data: { title: cleanName, artist: performer },
        });
        console.log(`✅ Created album: ${cleanName}`);
      }

      // Skip if song with this fileId already exists
      const existing = await prisma.song.findFirst({
        where: { telegramFileId: fileId },
      });
      if (existing) { skipped++; continue; }

      const songCount = await prisma.song.count({ where: { albumId: album.id } });

      await prisma.song.create({
        data: {
          albumId:        album.id,
          trackNumber:    trackNumber || (songCount + 1),
          title,
          telegramFileId: fileId,
          duration,
          partCount:      1,
        },
      });

      created++;
      console.log(`🎵 Saved: ${title} → ${album.title}`);
    }

    res.json({ message: 'Music sync complete', created, skipped });
  } catch (err) {
    console.error('Sync error:', err.message);
    res.status(500).json({ error: 'Sync failed', message: err.message });
  }
});

// ── POST /api/sync/covers ─────────────────────────────────────────────────────
// Reads Covers channel and links cover photos to albums/series by caption.
// Caption format: COVER_ALBUM:Befikre  or  COVER_SERIES:Deep Sleep
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

      const bestPhoto = photos[photos.length - 1];
      const fileId    = bestPhoto.file_id;

      const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
      const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

      if (albumMatch) {
        const name = albumMatch[1].trim();
        // Use normalized search so "Befikre" caption matches "Befikre" album
        const album = await findAlbumByNormalizedName(name);
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

// ── POST /api/sync/merge-albums ───────────────────────────────────────────────
// One-time utility to fix existing duplicate albums in the database.
// Merges albums with the same normalized name, keeping the oldest one.
// Call this ONCE from the dashboard or Postman to clean up existing duplicates.
router.post('/merge-albums', async (req, res) => {
  try {
    const albums = await prisma.album.findMany({ orderBy: { createdAt: 'asc' } });

    // Group albums by normalized name
    const groups = {};
    for (const album of albums) {
      const key = normalizeAlbumName(album.title);
      if (!groups[key]) groups[key] = [];
      groups[key].push(album);
    }

    let merged = 0;
    const details = [];

    for (const [key, group] of Object.entries(groups)) {
      if (group.length <= 1) continue;

      const keeper     = group[0]; // oldest = keeper
      const duplicates = group.slice(1);

      for (const dup of duplicates) {
        const songs = await prisma.song.findMany({ where: { albumId: dup.id } });

        for (const song of songs) {
          // Avoid trackNumber collision in keeper
          const conflict = await prisma.song.findFirst({
            where: { albumId: keeper.id, trackNumber: song.trackNumber },
          });

          if (conflict) {
            const maxTrack = await prisma.song.aggregate({
              where: { albumId: keeper.id },
              _max: { trackNumber: true },
            });
            await prisma.song.update({
              where: { id: song.id },
              data: {
                albumId:     keeper.id,
                trackNumber: (maxTrack._max.trackNumber || 0) + 1,
              },
            });
          } else {
            await prisma.song.update({
              where: { id: song.id },
              data: { albumId: keeper.id },
            });
          }
        }

        // Copy cover from duplicate if keeper doesn't have one
        if (!keeper.coverTelegramFileId && dup.coverTelegramFileId) {
          await prisma.album.update({
            where: { id: keeper.id },
            data:  { coverTelegramFileId: dup.coverTelegramFileId },
          });
          keeper.coverTelegramFileId = dup.coverTelegramFileId; // update local ref
        }

        // Hard delete the duplicate
        await prisma.album.delete({ where: { id: dup.id } });

        const msg = `Merged "${dup.title}" → "${keeper.title}" (${songs.length} songs moved)`;
        details.push(msg);
        merged++;
        console.log(`🔀 ${msg}`);
      }
    }

    res.json({ message: 'Merge complete', merged, details });
  } catch (err) {
    console.error('Merge error:', err.message);
    res.status(500).json({ error: 'Merge failed', message: err.message });
  }
});

module.exports = router;