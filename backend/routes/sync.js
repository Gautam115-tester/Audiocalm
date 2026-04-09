// backend/routes/sync.js

const express = require('express');
const router  = express.Router();
const axios   = require('axios');
const prisma  = require('../services/db');

// ── CORS ───────────────────────────────────────────────────────────────────
router.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', '*');
  res.header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.header('Access-Control-Allow-Headers', 'Content-Type, x-api-key');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

// ── Fetch updates from Telegram ────────────────────────────────────────────
async function fetchUpdates(offset = 0) {
  const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
    params: { offset, limit: 100, timeout: 0 },
  });
  return res.data.result || [];
}

// ── Normalize album name ───────────────────────────────────────────────────
// Strips noise suffixes so "Befikre" and
// "Befikre (Original Motion Picture Soundtrack)" resolve to the same album.
function normalizeAlbumName(name) {
  if (!name) return '';
  return name
    .replace(/\s*[\(\[].*?[\)\]]/g, '')   // remove anything in () or []
    .replace(/\boriginal\b.*$/gi, '')      // remove trailing "original ..."
    .replace(/\bsoundtrack\b.*$/gi, '')    // remove trailing "soundtrack ..."
    .replace(/\bost\b/gi, '')
    .replace(/_/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase();
}

// ── Extract album name from audio message ──────────────────────────────────
function extractAlbumName(audio) {
  // 1. Use Telegram's built-in album metadata if present
  if (audio.album && audio.album.trim().length > 0) {
    return audio.album.trim();
  }

  const fileName = audio.file_name || '';
  const baseName = fileName.replace(/\.[^.]+$/, '');

  // 2. Match prefix before _TR or _EP  e.g. "Befikre_TR04_You_And_Me.mp3" → "Befikre"
  const trackMatch = baseName.match(/^(.+?)_(?:TR|EP)\d+/i);
  if (trackMatch) {
    const raw = trackMatch[1].replace(/_/g, ' ').trim();
    return raw
      .split(' ')
      .map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
      .join(' ');
  }

  // 3. Heuristic: first 2 underscore-segments as album name
  const parts = baseName.split('_');
  if (parts.length > 2) {
    const candidate = parts.slice(0, 2).join(' ').trim();
    if (candidate.length > 0 && candidate.length < 60) {
      return candidate
        .split(' ')
        .map(w => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
        .join(' ');
    }
  }

  // 4. Absolute fallback
  console.warn(`  ⚠️  Could not extract album from filename "${fileName}", using performer`);
  return audio.performer || 'Unknown Album';
}

// ── POST /api/sync/music ───────────────────────────────────────────────────
router.post('/music', async (req, res) => {
  try {
    const updates = await fetchUpdates();

    // Fetch all active albums ONCE — in-memory lookup avoids repeated DB hits
    // that previously triggered Postgres 42P05 under PgBouncer transaction mode.
    const allAlbums = await prisma.album.findMany({ where: { isActive: true } });

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

      const trackMatch  = (audio.file_name || '').match(/_?TR(\d+)_?/i);
      const trackNumber = trackMatch ? parseInt(trackMatch[1]) : null;

      const rawAlbumName = extractAlbumName(audio);
      const normalized   = normalizeAlbumName(rawAlbumName);

      // In-memory album lookup — zero extra DB round-trips per track
      let album = allAlbums.find(a => normalizeAlbumName(a.title) === normalized) || null;

      if (!album) {
        album = await prisma.album.create({
          data: { title: rawAlbumName, artist: performer },
        });
        allAlbums.push(album); // keep cache current for remaining iterations
        console.log(`✅ Created album: "${rawAlbumName}"`);
      } else {
        if (!album.artist && performer !== 'Unknown') {
          await prisma.album.update({
            where: { id: album.id },
            data:  { artist: performer },
          });
          album.artist = performer;
        }
      }

      // Skip duplicate songs
      const existing = await prisma.song.findFirst({ where: { telegramFileId: fileId } });
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
      console.log(`🎵 Saved: "${title}" (TR${trackNumber}) → "${album.title}"`);
    }

    res.json({ message: 'Music sync complete', created, skipped });
  } catch (err) {
    console.error('Sync error:', err.message);
    res.status(500).json({ error: 'Sync failed', message: err.message });
  }
});

// ── POST /api/sync/covers ──────────────────────────────────────────────────
// Caption format: COVER_ALBUM:Befikre  or  COVER_SERIES:Deep Sleep
router.post('/covers', async (req, res) => {
  try {
    const updates = await fetchUpdates();

    // Fetch all albums once for normalized-name matching
    const allAlbums = await prisma.album.findMany({ where: { isActive: true } });

    let updated = 0;

    for (const update of updates) {
      const post = update.channel_post;
      if (!post) continue;
      if (String(post.chat.id) !== String(process.env.TELEGRAM_COVERS_CHANNEL_ID)) continue;

      const caption = post.caption || '';
      const photos  = post.photo;
      if (!photos || photos.length === 0) continue;

      const bestPhoto = photos[photos.length - 1]; // highest resolution
      const fileId    = bestPhoto.file_id;

      const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
      const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

      if (albumMatch) {
        const name       = albumMatch[1].trim();
        const normalized = normalizeAlbumName(name);
        const album      = allAlbums.find(a => normalizeAlbumName(a.title) === normalized) || null;

        if (album) {
          await prisma.album.update({
            where: { id: album.id },
            data:  { coverTelegramFileId: fileId },
          });
          console.log(`🖼️  Cover set for album: "${album.title}"`);
          updated++;
        } else {
          console.warn(`⚠️  Cover: no album found matching "${name}"`);
        }
      }

      if (seriesMatch) {
        const name   = seriesMatch[1].trim();
        const series = await prisma.series.findFirst({
          where: { title: { contains: name, mode: 'insensitive' } },
        });
        if (series) {
          await prisma.series.update({
            where: { id: series.id },
            data:  { coverTelegramFileId: fileId },
          });
          console.log(`🖼️  Cover set for series: "${series.title}"`);
          updated++;
        } else {
          console.warn(`⚠️  Cover: no series found matching "${name}"`);
        }
      }
    }

    res.json({ message: 'Covers sync complete', updated });
  } catch (err) {
    console.error('Covers sync error:', err.message);
    res.status(500).json({ error: 'Covers sync failed', message: err.message });
  }
});

// ── POST /api/sync/merge-albums ────────────────────────────────────────────
// One-time utility: merges duplicate albums with the same normalized name.
router.post('/merge-albums', async (req, res) => {
  try {
    const albums = await prisma.album.findMany({ orderBy: { createdAt: 'asc' } });

    const groups = {};
    for (const album of albums) {
      const key = normalizeAlbumName(album.title);
      if (!key) continue;
      if (!groups[key]) groups[key] = [];
      groups[key].push(album);
    }

    let merged = 0;
    const details = [];

    for (const [, group] of Object.entries(groups)) {
      if (group.length <= 1) continue;

      const keeper     = group[0];
      const duplicates = group.slice(1);

      for (const dup of duplicates) {
        const songs = await prisma.song.findMany({ where: { albumId: dup.id } });

        for (const song of songs) {
          const conflict = await prisma.song.findFirst({
            where: { albumId: keeper.id, trackNumber: song.trackNumber },
          });

          if (conflict) {
            const maxTrack = await prisma.song.aggregate({
              where: { albumId: keeper.id },
              _max:  { trackNumber: true },
            });
            await prisma.song.update({
              where: { id: song.id },
              data:  { albumId: keeper.id, trackNumber: (maxTrack._max.trackNumber || 0) + 1 },
            });
          } else {
            await prisma.song.update({
              where: { id: song.id },
              data:  { albumId: keeper.id },
            });
          }
        }

        if (!keeper.coverTelegramFileId && dup.coverTelegramFileId) {
          await prisma.album.update({
            where: { id: keeper.id },
            data:  { coverTelegramFileId: dup.coverTelegramFileId },
          });
          keeper.coverTelegramFileId = dup.coverTelegramFileId;
        }

        if (!keeper.artist && dup.artist) {
          await prisma.album.update({
            where: { id: keeper.id },
            data:  { artist: dup.artist },
          });
          keeper.artist = dup.artist;
        }

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