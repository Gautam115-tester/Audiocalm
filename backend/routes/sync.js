// routes/sync.js
const express = require('express');
const router  = express.Router();
const axios   = require('axios');
const prisma  = require('../services/db');
const fs      = require('fs');
const path    = require('path');

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

// ─────────────────────────────────────────────────────────────────────────────
// OFFSET TRACKING
//
// ⚠️  RULE 1 — Save offset ONLY after DB success.
//     Telegram's getUpdates queue is destructive: once you advance the offset,
//     those older updates are deleted from Telegram forever.
//     If we save the offset before the DB write and the write fails,
//     those messages are permanently lost on the next sync.
//
// ⚠️  RULE 2 — Music and covers share ONE offset.
//     getUpdates returns ALL updates from ALL channels in a single stream.
//     If music sync advances the offset, it silently consumes and discards
//     cover posts (they don't match the music channel ID filter).
//     Fix: fetch once, split by channel — never fetch twice.
// ─────────────────────────────────────────────────────────────────────────────
const OFFSET_FILE = path.join(__dirname, '../.sync_offset.json');

function readOffset() {
  try {
    const data = JSON.parse(fs.readFileSync(OFFSET_FILE, 'utf8'));
    // Handle both old format { music, covers } and new { offset }
    return typeof data.offset === 'number' ? data.offset : 0;
  } catch {
    return 0;
  }
}

function saveOffset(value) {
  fs.writeFileSync(OFFSET_FILE, JSON.stringify({ offset: value }), 'utf8');
}

// ─────────────────────────────────────────────────────────────────────────────
// FETCH ALL UPDATES — paginates through the full queue
// Returns { updates, nextOffset } but does NOT save the offset.
// Caller must save it only after a successful DB write.
// ─────────────────────────────────────────────────────────────────────────────
async function fetchAllUpdates() {
  let offset     = readOffset();
  let nextOffset = offset;
  const all      = [];

  while (true) {
    const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
      params: { offset, limit: 100, timeout: 0 },
    });

    const batch = res.data.result || [];
    if (batch.length === 0) break;

    all.push(...batch);
    offset     = batch[batch.length - 1].update_id + 1;
    nextOffset = offset;
  }

  return { updates: all, nextOffset };
}

// ─────────────────────────────────────────────────────────────────────────────
// ALBUM NAME CLEANER
// ─────────────────────────────────────────────────────────────────────────────
function extractAndCleanAlbumName(fileName, performer) {
  if (!fileName) return performer || 'Unknown';

  const albumMatch = fileName.match(
    /^(.+?)(?:[\s_(\[-]*(?:Original|OST|Soundtrack|TR\d)|\.[a-z0-9]{3,4}$|$)/i
  );

  let albumName = albumMatch?.[1] || performer;

  albumName = albumName
    .replace(/[_\-\.]+/g, ' ')
    .replace(/\([^)]*\)/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase()
    .replace(/\b\w/g, (c) => c.toUpperCase());

  return albumName || 'Unknown Album';
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/music
//
// DUPLICATE LOGIC (2-layer):
//   Layer 1 — telegramFileId  : same exact file → skip always
//   Layer 2 — title + albumId : same name in same album → skip
//   Same title in a DIFFERENT album → allowed ✅
// ─────────────────────────────────────────────────────────────────────────────
router.post('/music', async (req, res) => {
  try {
    // ── Step 1: Fetch new updates (offset NOT saved yet) ──────────────────────
    const { updates, nextOffset } = await fetchAllUpdates();

    const audioPosts = updates.filter((u) => {
      const post = u.channel_post;
      return (
        post &&
        post.audio &&
        String(post.chat.id) === String(process.env.TELEGRAM_MUSIC_CHANNEL_ID)
      );
    });

    if (audioPosts.length === 0) {
      // No music posts, but still advance offset past any noise (cover posts etc.)
      if (updates.length > 0) saveOffset(nextOffset);
      return res.json({ message: 'Music sync complete', created: 0, skipped: 0 });
    }

    console.log(`📥 Processing ${audioPosts.length} new audio posts…`);

    // ── Step 2: Pre-load all albums into memory (1 DB query) ──────────────────
    const existingAlbums = await prisma.album.findMany({
      select: { id: true, title: true },
    });
    const albumMap = new Map(
      existingAlbums.map((a) => [a.title.toLowerCase(), a])
    );

    // ── Step 3: Pre-load all songs into memory (1 DB query) ───────────────────
    const existingSongs = await prisma.song.findMany({
      select: { telegramFileId: true, title: true, albumId: true },
    });
    const existingFileIds = new Set(
      existingSongs.map((s) => s.telegramFileId).filter(Boolean)
    );
    const existingTitleAlbum = new Set(
      existingSongs.map((s) => `${s.title.toLowerCase()}::${s.albumId}`)
    );

    // ── Step 4: Collect albums that need creating ─────────────────────────────
    const albumsToCreate = new Map();
    for (const update of audioPosts) {
      const audio     = update.channel_post.audio;
      const performer = audio.performer || 'Unknown';
      const albumName = extractAndCleanAlbumName(audio.file_name, performer);
      const key       = albumName.toLowerCase();
      if (!albumMap.has(key) && !albumsToCreate.has(key)) {
        albumsToCreate.set(key, { title: albumName, artist: performer });
      }
    }

    // ── Step 5: Bulk-create missing albums (1 DB query) ───────────────────────
    if (albumsToCreate.size > 0) {
      await prisma.album.createMany({
        data:           [...albumsToCreate.values()],
        skipDuplicates: true,
      });
      console.log(`✅ Bulk-created ${albumsToCreate.size} new album(s)`);

      const freshAlbums = await prisma.album.findMany({
        select: { id: true, title: true },
      });
      freshAlbums.forEach((a) => albumMap.set(a.title.toLowerCase(), a));
    }

    // ── Step 6: Pre-load max track numbers per album (1 DB query) ─────────────
    const trackAgg = await prisma.song.groupBy({
      by:   ['albumId'],
      _max: { trackNumber: true },
    });
    const maxTrackMap     = new Map(trackAgg.map((r) => [r.albumId, r._max.trackNumber || 0]));
    const pendingTrackMap = new Map();

    // ── Step 7: Build song insert list ────────────────────────────────────────
    const songsToCreate = [];
    let skipped = 0;

    for (const update of audioPosts) {
      const audio     = update.channel_post.audio;
      const title     = audio.title || audio.file_name || 'Unknown';
      const performer = audio.performer || 'Unknown';
      const fileId    = audio.file_id;
      const duration  = audio.duration;

      // Layer-1: same Telegram file
      if (existingFileIds.has(fileId)) {
        skipped++;
        continue;
      }

      const albumName = extractAndCleanAlbumName(audio.file_name, performer);
      const album     = albumMap.get(albumName.toLowerCase());

      if (!album) {
        console.warn(`⚠️  No album found for "${albumName}" — skipping: ${title}`);
        skipped++;
        continue;
      }

      // Layer-2: same title in same album
      const titleAlbumKey = `${title.toLowerCase()}::${album.id}`;
      if (existingTitleAlbum.has(titleAlbumKey)) {
        skipped++;
        continue;
      }

      // ── Track number (collision-safe, no per-song DB queries) ────────────
      const trackMatch = audio.file_name?.match(/TR(\d+)/i);
      let   trackNum   = trackMatch ? parseInt(trackMatch[1]) : null;

      if (trackNum !== null && pendingTrackMap.has(`${album.id}::${trackNum}`)) {
        trackNum = null; // already claimed in this batch → append instead
      }

      if (trackNum === null) {
        const dbMax      = maxTrackMap.get(album.id) || 0;
        const pendingMax = pendingTrackMap.get(`${album.id}::__max`) || 0;
        trackNum         = Math.max(dbMax, pendingMax) + 1;
      }

      pendingTrackMap.set(`${album.id}::${trackNum}`, true);
      const curMax = pendingTrackMap.get(`${album.id}::__max`) || 0;
      pendingTrackMap.set(`${album.id}::__max`, Math.max(curMax, trackNum));

      existingFileIds.add(fileId);
      existingTitleAlbum.add(titleAlbumKey);

      songsToCreate.push({
        albumId:        album.id,
        trackNumber:    trackNum,
        title,
        telegramFileId: fileId,
        duration,
        partCount:      1,
      });
    }

    // ── Step 8: DB write first, THEN save offset ──────────────────────────────
    if (songsToCreate.length > 0) {
      await prisma.song.createMany({
        data:           songsToCreate,
        skipDuplicates: true,
      });
      console.log(`🎵 Bulk-inserted ${songsToCreate.length} song(s)`);
    }

    // ✅ Offset only advances after a successful DB write.
    // If prisma.song.createMany throws, we never reach this line,
    // so the same updates will be retried on the next sync call.
    saveOffset(nextOffset);

    res.json({
      message: 'Music sync complete',
      created: songsToCreate.length,
      skipped,
    });
  } catch (err) {
    console.error('Music sync error:', err.message);
    // Offset intentionally NOT saved — next sync will retry these updates
    res.status(500).json({ error: 'Sync failed', message: err.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/covers
// ─────────────────────────────────────────────────────────────────────────────
router.post('/covers', async (req, res) => {
  try {
    const { updates, nextOffset } = await fetchAllUpdates();

    const coverPosts = updates.filter((u) => {
      const post = u.channel_post;
      return (
        post &&
        post.photo &&
        String(post.chat.id) === String(process.env.TELEGRAM_COVERS_CHANNEL_ID)
      );
    });

    if (coverPosts.length === 0) {
      if (updates.length > 0) saveOffset(nextOffset);
      return res.json({ message: 'Covers sync complete', updated: 0 });
    }

    const [allAlbums, allSeries] = await Promise.all([
      prisma.album.findMany({ select: { id: true, title: true } }),
      prisma.series.findMany({ select: { id: true, title: true } }),
    ]);

    const albumMap  = new Map(allAlbums.map((a) => [a.title.toLowerCase(), a]));
    const seriesMap = new Map(allSeries.map((s) => [s.title.toLowerCase(), s]));

    const albumCoverUpdates  = [];
    const seriesCoverUpdates = [];

    for (const update of coverPosts) {
      const post    = update.channel_post;
      const fileId  = post.photo[post.photo.length - 1].file_id;
      const caption = post.caption || '';

      const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
      const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

      if (albumMatch) {
        const name  = albumMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
        const album = albumMap.get(name)
          ?? [...albumMap.values()].find((a) => a.title.toLowerCase().includes(name));
        if (album) {
          albumCoverUpdates.push({ id: album.id, fileId });
          console.log(`🖼️  Queued cover for album: ${album.title}`);
        } else {
          console.warn(`⚠️  No album matched cover caption: "${name}"`);
        }
      }

      if (seriesMatch) {
        const name   = seriesMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
        const series = seriesMap.get(name)
          ?? [...seriesMap.values()].find((s) => s.title.toLowerCase().includes(name));
        if (series) {
          seriesCoverUpdates.push({ id: series.id, fileId });
          console.log(`🖼️  Queued cover for series: ${series.title}`);
        } else {
          console.warn(`⚠️  No series matched cover caption: "${name}"`);
        }
      }
    }

    // DB writes first, offset save second
    await Promise.all([
      ...albumCoverUpdates.map(({ id, fileId }) =>
        prisma.album.update({ where: { id }, data: { coverTelegramFileId: fileId } })
      ),
      ...seriesCoverUpdates.map(({ id, fileId }) =>
        prisma.series.update({ where: { id }, data: { coverTelegramFileId: fileId } })
      ),
    ]);

    // ✅ Only save offset after all DB writes succeed
    saveOffset(nextOffset);

    const updated = albumCoverUpdates.length + seriesCoverUpdates.length;
    res.json({ message: 'Covers sync complete', updated });
  } catch (err) {
    console.error('Covers sync error:', err.message);
    res.status(500).json({ error: 'Covers sync failed', message: err.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/reset-offset — re-process all Telegram history from scratch
// ─────────────────────────────────────────────────────────────────────────────
router.post('/reset-offset', (req, res) => {
  try {
    saveOffset(0);
    res.json({ message: 'Offset reset. Next sync will re-process all Telegram history.' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;