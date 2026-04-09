// routes/sync.js
// Syncs music and cover art from Telegram channels into the database.
//
// HOW IT WORKS
//  Telegram bots cannot call getChatHistory on channels they don't own.
//  The workaround is forwardMessages: forward batches of message IDs from the
//  source channel to a private "dump" chat. The bot receives the forwarded
//  messages with full metadata (audio, photo, caption, forward_origin).
//
// STATE
//  The last-seen message ID cursor is stored in the SyncState table so it
//  survives Render deploys (Render resets the container filesystem on deploy).
//
// CONCURRENCY
//  Each sync type (music / covers) is guarded by a running flag. A 409 is
//  returned if a sync is already in progress.

const express = require('express');
const router  = express.Router();
const axios   = require('axios');
const prisma  = require('../services/db');

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

// ── Startup validation ────────────────────────────────────────────────────────
for (const key of ['TELEGRAM_BOT_TOKEN', 'TELEGRAM_MUSIC_CHANNEL_ID', 'TELEGRAM_COVERS_CHANNEL_ID', 'TELEGRAM_DUMP_CHAT_ID']) {
  if (!process.env[key]) console.error(`❌ Missing env var: ${key}`);
}

// ── State helpers (DB-backed, memory fallback) ────────────────────────────────
let memState = { musicLastMsgId: 0, coversLastMsgId: 0 };

async function readState() {
  try {
    const rows  = await prisma.syncState.findMany();
    const state = { musicLastMsgId: 0, coversLastMsgId: 0 };
    for (const row of rows) {
      if (row.key === 'musicLastMsgId')  state.musicLastMsgId  = parseInt(row.value) || 0;
      if (row.key === 'coversLastMsgId') state.coversLastMsgId = parseInt(row.value) || 0;
    }
    memState = state;
    return state;
  } catch (err) {
    console.warn('⚠️  readState DB error — using memory fallback:', err.message);
    return memState;
  }
}

async function saveState(patch) {
  memState = { ...memState, ...patch };
  try {
    await Promise.all(
      Object.entries(patch).map(([key, value]) =>
        prisma.syncState.upsert({
          where:  { key },
          update: { value: String(value) },
          create: { key, value: String(value) },
        })
      )
    );
  } catch (err) {
    console.warn('⚠️  saveState DB error — state is memory-only:', err.message);
  }
}

// ── In-memory sync status for the /status endpoint ───────────────────────────
const syncStatus = {
  music:  { running: false, lastResult: null, lastError: null, lastRun: null },
  covers: { running: false, lastResult: null, lastError: null, lastRun: null },
};

// ── fetchChannelMessages ──────────────────────────────────────────────────────
// Forwards batches of message IDs from a channel to TELEGRAM_DUMP_CHAT_ID.
// Returns the array of forwarded message objects received by the bot.
const BATCH_SIZE   = 100; // Telegram hard limit for forwardMessages
const MAX_EMPTY    = 5;   // consecutive empty batches → stop

async function fetchChannelMessages(channelId, fromMsgId = 1) {
  const DUMP_CHAT = process.env.TELEGRAM_DUMP_CHAT_ID;
  if (!DUMP_CHAT)  throw new Error('TELEGRAM_DUMP_CHAT_ID not set');
  if (!channelId)  throw new Error('channelId not set — check .env');

  const messages       = [];
  let   currentId      = fromMsgId;
  let   emptyStreak    = 0;

  while (emptyStreak < MAX_EMPTY) {
    const msgIds = Array.from({ length: BATCH_SIZE }, (_, i) => currentId + i);

    let forwarded = [];
    try {
      const res = await axios.post(`${TELEGRAM_API}/forwardMessages`, {
        chat_id:              DUMP_CHAT,
        from_chat_id:         channelId,
        message_ids:          msgIds,
        disable_notification: true,
      });
      forwarded = res.data.result || [];
    } catch (err) {
      if (err.response?.status === 400) break; // past end of channel
      throw err;
    }

    if (forwarded.length === 0) {
      emptyStreak++;
    } else {
      emptyStreak = 0;
      messages.push(...forwarded);
    }

    currentId += BATCH_SIZE;
    await new Promise((r) => setTimeout(r, 400)); // stay under 30 req/s global limit
  }

  return messages;
}

// Channel forwards carry the source message ID in forward_origin.message_id
function getOriginalMsgId(msg) {
  return (
    msg?.forward_origin?.message_id ||
    msg?.forward_from_message_id    ||
    msg?.message_id                 ||
    0
  );
}

// ── Album name cleaner (used during music sync) ───────────────────────────────
function cleanAlbumName(fileName, performer) {
  if (!fileName) return performer || 'Unknown';
  const m    = fileName.match(/^(.+?)(?:[\s_([\-]*(?:Original|OST|Soundtrack|TR\d)|\.[a-z0-9]{3,4}$|$)/i);
  let   name = m?.[1] || performer || 'Unknown';
  name = name
    .replace(/[_\-\.]+/g, ' ')
    .replace(/\([^)]*\)/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase()
    .replace(/\b\w/g, (c) => c.toUpperCase());
  return name || 'Unknown Album';
}

// ── runMusicSync ──────────────────────────────────────────────────────────────
async function runMusicSync() {
  const state     = await readState();
  const fromMsgId = (state.musicLastMsgId || 0) + 1;
  const channelId = process.env.TELEGRAM_MUSIC_CHANNEL_ID;

  console.log(`📡 [Music] Syncing from message ID ${fromMsgId}…`);
  const raw = await fetchChannelMessages(channelId, fromMsgId);
  console.log(`📦 [Music] ${raw.length} messages received`);

  // Track highest message ID regardless of content
  let highestMsgId = state.musicLastMsgId || 0;
  for (const m of raw) {
    const id = getOriginalMsgId(m);
    if (id > highestMsgId) highestMsgId = id;
  }

  const audioPosts = raw.filter((m) => m.audio != null);
  console.log(`🎵 [Music] ${audioPosts.length} audio messages`);

  if (audioPosts.length === 0) {
    await saveState({ musicLastMsgId: highestMsgId });
    return { created: 0, skipped: 0, scanned: raw.length };
  }

  // Pre-load albums and songs for deduplication
  const existingAlbums = await prisma.album.findMany({ select: { id: true, title: true } });
  const albumMap       = new Map(existingAlbums.map((a) => [a.title.toLowerCase(), a]));

  const existingSongs    = await prisma.song.findMany({ select: { telegramFileId: true, title: true, albumId: true } });
  const seenFileIds      = new Set(existingSongs.map((s) => s.telegramFileId).filter(Boolean));
  const seenTitleAlbum   = new Set(existingSongs.map((s) => `${s.title.toLowerCase()}::${s.albumId}`));

  // Determine which albums need to be created
  const albumsToCreate = new Map();
  for (const msg of audioPosts) {
    const a        = msg.audio;
    const name     = cleanAlbumName(a.file_name, a.performer);
    const key      = name.toLowerCase();
    if (!albumMap.has(key) && !albumsToCreate.has(key)) {
      albumsToCreate.set(key, { title: name, artist: a.performer || null });
    }
  }

  if (albumsToCreate.size > 0) {
    await prisma.album.createMany({ data: [...albumsToCreate.values()], skipDuplicates: true });
    console.log(`✅ [Music] Created ${albumsToCreate.size} album(s)`);
    // Reload album map with new IDs
    const fresh = await prisma.album.findMany({ select: { id: true, title: true } });
    fresh.forEach((a) => albumMap.set(a.title.toLowerCase(), a));
  }

  // Build track-number helpers (avoid duplicates within a session)
  const trackAgg    = await prisma.song.groupBy({ by: ['albumId'], _max: { trackNumber: true } });
  const maxTrackMap = new Map(trackAgg.map((r) => [r.albumId, r._max.trackNumber || 0]));
  const sessionMax  = new Map(); // albumId → highest track number added this session

  const songsToCreate = [];
  let skipped = 0;

  for (const msg of audioPosts) {
    const audio     = msg.audio;
    const title     = audio.title || audio.file_name || 'Unknown';
    const performer = audio.performer || null;
    const fileId    = audio.file_id;
    const duration  = audio.duration ?? null;

    // Skip duplicates by fileId first, then by title+album
    if (seenFileIds.has(fileId)) { skipped++; continue; }

    const albumName = cleanAlbumName(audio.file_name, performer);
    const album     = albumMap.get(albumName.toLowerCase());
    if (!album) { console.warn(`⚠️  [Music] No album matched for "${albumName}"`); skipped++; continue; }

    const titleKey = `${title.toLowerCase()}::${album.id}`;
    if (seenTitleAlbum.has(titleKey)) { skipped++; continue; }

    // Determine track number: prefer TR## in filename, else auto-increment
    const trMatch = audio.file_name?.match(/TR(\d+)/i);
    let   trackNum = trMatch ? parseInt(trMatch[1]) : null;

    // If TR## already used this session, fall back to auto
    if (trackNum !== null && sessionMax.has(`${album.id}::${trackNum}`)) trackNum = null;

    if (trackNum === null) {
      const dbMax  = maxTrackMap.get(album.id) || 0;
      const sesMax = sessionMax.get(`${album.id}::__max`) || 0;
      trackNum     = Math.max(dbMax, sesMax) + 1;
    }

    sessionMax.set(`${album.id}::${trackNum}`, true);
    sessionMax.set(`${album.id}::__max`, Math.max(sessionMax.get(`${album.id}::__max`) || 0, trackNum));
    seenFileIds.add(fileId);
    seenTitleAlbum.add(titleKey);

    songsToCreate.push({
      albumId:        album.id,
      trackNumber:    trackNum,
      title,
      artist:         performer,
      telegramFileId: fileId,
      duration,
      partCount:      1,
    });
  }

  if (songsToCreate.length > 0) {
    await prisma.song.createMany({ data: songsToCreate, skipDuplicates: true });
    console.log(`🎵 [Music] Inserted ${songsToCreate.length} songs, skipped ${skipped}`);
  }

  await saveState({ musicLastMsgId: highestMsgId });
  return { created: songsToCreate.length, skipped, scanned: raw.length };
}

// ── runCoversSync ─────────────────────────────────────────────────────────────
async function runCoversSync() {
  const state     = await readState();
  const fromMsgId = (state.coversLastMsgId || 0) + 1;
  const channelId = process.env.TELEGRAM_COVERS_CHANNEL_ID;

  console.log(`📡 [Covers] Syncing from message ID ${fromMsgId}…`);
  const raw = await fetchChannelMessages(channelId, fromMsgId);
  console.log(`📦 [Covers] ${raw.length} messages received`);

  let highestMsgId = state.coversLastMsgId || 0;
  for (const m of raw) {
    const id = getOriginalMsgId(m);
    if (id > highestMsgId) highestMsgId = id;
  }

  const photoMessages = raw.filter((m) => m.photo);
  console.log(`🖼️  [Covers] ${photoMessages.length} photo messages`);

  if (photoMessages.length === 0) {
    await saveState({ coversLastMsgId: highestMsgId });
    return { updated: 0, scanned: raw.length };
  }

  const [allAlbums, allSeries] = await Promise.all([
    prisma.album.findMany({ select: { id: true, title: true } }),
    prisma.series.findMany({ select: { id: true, title: true } }),
  ]);

  const albumMap  = new Map(allAlbums.map((a) => [a.title.toLowerCase(), a]));
  const seriesMap = new Map(allSeries.map((s) => [s.title.toLowerCase(), s]));

  const albumUpdates  = [];
  const seriesUpdates = [];

  for (const msg of photoMessages) {
    // Caption may be on the original message (via forward_origin) or the forwarded copy
    const caption = msg.caption || msg.forward_origin?.caption || '';
    const fileId  = msg.photo[msg.photo.length - 1].file_id; // highest resolution

    const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
    const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

    if (albumMatch) {
      const name  = albumMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
      // Exact match first, then partial
      const album = albumMap.get(name) ?? [...albumMap.values()].find((a) => a.title.toLowerCase().includes(name));
      if (album) {
        albumUpdates.push({ id: album.id, fileId });
        console.log(`🖼️  [Covers] Matched album: "${album.title}"`);
      } else {
        console.warn(`⚠️  [Covers] No album matched for: "${name}"`);
      }
    }

    if (seriesMatch) {
      const name   = seriesMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
      const series = seriesMap.get(name) ?? [...seriesMap.values()].find((s) => s.title.toLowerCase().includes(name));
      if (series) {
        seriesUpdates.push({ id: series.id, fileId });
        console.log(`🖼️  [Covers] Matched series: "${series.title}"`);
      } else {
        console.warn(`⚠️  [Covers] No series matched for: "${name}"`);
      }
    }
  }

  await Promise.all([
    ...albumUpdates.map(({ id, fileId }) =>
      prisma.album.update({ where: { id }, data: { coverTelegramFileId: fileId } })
    ),
    ...seriesUpdates.map(({ id, fileId }) =>
      prisma.series.update({ where: { id }, data: { coverTelegramFileId: fileId } })
    ),
  ]);

  await saveState({ coversLastMsgId: highestMsgId });
  return { updated: albumUpdates.length + seriesUpdates.length, scanned: raw.length };
}

// ── ROUTES ────────────────────────────────────────────────────────────────────

// POST /api/sync/music
router.post('/music', (req, res) => {
  if (syncStatus.music.running)
    return res.status(409).json({ message: 'Music sync already running — poll GET /api/sync/status' });

  syncStatus.music = { ...syncStatus.music, running: true, lastError: null, lastRun: new Date().toISOString() };
  res.status(202).json({ message: 'Music sync started. Poll GET /api/sync/status for result.' });

  runMusicSync()
    .then((r)  => { syncStatus.music.lastResult = r; console.log('✅ [Music] sync done:', r); })
    .catch((e) => { syncStatus.music.lastError  = e.message; console.error('❌ [Music]', e.message); })
    .finally(() => { syncStatus.music.running = false; });
});

// POST /api/sync/covers
router.post('/covers', (req, res) => {
  if (syncStatus.covers.running)
    return res.status(409).json({ message: 'Covers sync already running — poll GET /api/sync/status' });

  syncStatus.covers = { ...syncStatus.covers, running: true, lastError: null, lastRun: new Date().toISOString() };
  res.status(202).json({ message: 'Covers sync started. Poll GET /api/sync/status for result.' });

  runCoversSync()
    .then((r)  => { syncStatus.covers.lastResult = r; console.log('✅ [Covers] sync done:', r); })
    .catch((e) => { syncStatus.covers.lastError  = e.message; console.error('❌ [Covers]', e.message); })
    .finally(() => { syncStatus.covers.running = false; });
});

// GET /api/sync/status
router.get('/status', async (req, res, next) => {
  try {
    const state = await readState();
    res.json({ success: true, data: { music: syncStatus.music, covers: syncStatus.covers, state } });
  } catch (err) { next(err); }
});

// POST /api/sync/reset — re-scans everything from message ID 1
router.post('/reset', async (req, res, next) => {
  try {
    await saveState({ musicLastMsgId: 0, coversLastMsgId: 0 });
    syncStatus.music.lastResult  = null;
    syncStatus.covers.lastResult = null;
    res.json({ success: true, message: 'Sync state reset. Next run will scan all messages from the start.' });
  } catch (err) { next(err); }
});

module.exports = router;