// routes/sync.js
const express = require('express');
const router  = express.Router();
const axios   = require('axios');
const prisma  = require('../services/db');

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

// ─────────────────────────────────────────────────────────────────────────────
// ENV VALIDATION — warn at startup so issues are obvious in Render logs
// ─────────────────────────────────────────────────────────────────────────────
['TELEGRAM_BOT_TOKEN','TELEGRAM_MUSIC_CHANNEL_ID','TELEGRAM_COVERS_CHANNEL_ID','TELEGRAM_DUMP_CHAT_ID']
  .forEach(k => { if (!process.env[k]) console.error(`❌ Missing env var: ${k}`); });

// ─────────────────────────────────────────────────────────────────────────────
// STATE — persisted in PostgreSQL (SyncState model).
// Render's filesystem resets on every deploy — never use fs for state.
// Falls back to in-memory if DB is temporarily unreachable.
// ─────────────────────────────────────────────────────────────────────────────
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
    console.warn('⚠️  readState DB error, using memory fallback:', err.message);
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
    console.warn('⚠️  saveState DB error, state is memory-only:', err.message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// IN-MEMORY SYNC STATUS — for dashboard polling
// ─────────────────────────────────────────────────────────────────────────────
const syncStatus = {
  music:  { running: false, lastResult: null, lastError: null, lastRun: null },
  covers: { running: false, lastResult: null, lastError: null, lastRun: null },
};

// ─────────────────────────────────────────────────────────────────────────────
// FETCH CHANNEL MESSAGES via forwardMessages
//
// Telegram doesn't expose getChatHistory for bots. forwardMessages is the only
// way to read full historical channel content with a bot token. We forward
// batches of 100 IDs to a private dump chat and inspect the returned metadata.
// ─────────────────────────────────────────────────────────────────────────────
const BATCH_SIZE = 100; // Telegram hard limit for forwardMessages
const MAX_EMPTY  = 5;   // consecutive empty batches before stopping

async function fetchChannelMessages(channelId, fromMsgId = 1) {
  const DUMP_CHAT = process.env.TELEGRAM_DUMP_CHAT_ID;
  if (!DUMP_CHAT)   throw new Error('TELEGRAM_DUMP_CHAT_ID not set');
  if (!channelId)   throw new Error('channelId not set — check .env');

  const messages       = [];
  let currentId        = fromMsgId;
  let consecutiveEmpty = 0;

  while (consecutiveEmpty < MAX_EMPTY) {
    const msgIds = Array.from({ length: BATCH_SIZE }, (_, i) => currentId + i);

    let forwarded;
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
      consecutiveEmpty++;
    } else {
      consecutiveEmpty = 0;
      messages.push(...forwarded);
    }
    currentId += BATCH_SIZE;

    await new Promise(r => setTimeout(r, 400)); // rate limit: 30 req/s global
  }

  return messages;
}

// ─────────────────────────────────────────────────────────────────────────────
// GET ORIGINAL MESSAGE ID
// Channel forwards put the source id in forward_origin.message_id
// (not forward_from_message_id, which is for user-to-user forwards)
// ─────────────────────────────────────────────────────────────────────────────
function getOriginalMsgId(msg) {
  return msg?.forward_origin?.message_id ||
         msg?.forward_from_message_id    ||
         msg?.message_id;
}

// ─────────────────────────────────────────────────────────────────────────────
// ALBUM NAME CLEANER
// ─────────────────────────────────────────────────────────────────────────────
function extractAndCleanAlbumName(fileName, performer) {
  if (!fileName) return performer || 'Unknown';
  const m = fileName.match(/^(.+?)(?:[\s_(\[-]*(?:Original|OST|Soundtrack|TR\d)|\.[a-z0-9]{3,4}$|$)/i);
  let name = m?.[1] || performer;
  name = name.replace(/[_\-\.]+/g, ' ').replace(/\([^)]*\)/g, '').replace(/\s+/g, ' ').trim()
             .toLowerCase().replace(/\b\w/g, c => c.toUpperCase());
  return name || 'Unknown Album';
}

// ─────────────────────────────────────────────────────────────────────────────
// MUSIC SYNC LOGIC
// ─────────────────────────────────────────────────────────────────────────────
async function runMusicSync() {
  const state     = await readState();
  const fromMsgId = (state.musicLastMsgId || 0) + 1;
  const channelId = process.env.TELEGRAM_MUSIC_CHANNEL_ID;

  console.log(`📡 [Music] Fetching from message ID ${fromMsgId}…`);
  const rawMessages = await fetchChannelMessages(channelId, fromMsgId);
  console.log(`📦 [Music] ${rawMessages.length} forwarded messages received`);

  // Compute highestMsgId before any early return
  let highestMsgId = state.musicLastMsgId || 0;
  for (const m of rawMessages) {
    const origId = getOriginalMsgId(m);
    if (origId > highestMsgId) highestMsgId = origId;
  }

  const audioPosts = rawMessages.filter(m => m.audio != null);
  console.log(`🎵 [Music] ${audioPosts.length} audio messages`);

  // Save state always — prevents re-scanning same IDs on next run
  if (audioPosts.length === 0) {
    await saveState({ musicLastMsgId: highestMsgId });
    return { created: 0, skipped: 0, scanned: rawMessages.length };
  }

  // Pre-load
  const existingAlbums = await prisma.album.findMany({ select: { id: true, title: true } });
  const albumMap = new Map(existingAlbums.map(a => [a.title.toLowerCase(), a]));

  const existingSongs      = await prisma.song.findMany({ select: { telegramFileId: true, title: true, albumId: true } });
  const existingFileIds    = new Set(existingSongs.map(s => s.telegramFileId).filter(Boolean));
  const existingTitleAlbum = new Set(existingSongs.map(s => `${s.title.toLowerCase()}::${s.albumId}`));

  // Create missing albums
  const albumsToCreate = new Map();
  for (const msg of audioPosts) {
    const a = msg.audio;
    const albumName = extractAndCleanAlbumName(a.file_name, a.performer || 'Unknown');
    const key = albumName.toLowerCase();
    if (!albumMap.has(key) && !albumsToCreate.has(key)) {
      albumsToCreate.set(key, { title: albumName, artist: a.performer || 'Unknown' });
    }
  }
  if (albumsToCreate.size > 0) {
    await prisma.album.createMany({ data: [...albumsToCreate.values()], skipDuplicates: true });
    console.log(`✅ [Music] Created ${albumsToCreate.size} album(s)`);
    const fresh = await prisma.album.findMany({ select: { id: true, title: true } });
    fresh.forEach(a => albumMap.set(a.title.toLowerCase(), a));
  }

  // Track number helpers
  const trackAgg    = await prisma.song.groupBy({ by: ['albumId'], _max: { trackNumber: true } });
  const maxTrackMap = new Map(trackAgg.map(r => [r.albumId, r._max.trackNumber || 0]));
  const pendingTrackMap = new Map();

  const songsToCreate = [];
  let skipped = 0;

  for (const msg of audioPosts) {
    const audio     = msg.audio;
    const title     = audio.title || audio.file_name || 'Unknown';
    const performer = audio.performer || 'Unknown';
    const fileId    = audio.file_id;
    const duration  = audio.duration ?? null;

    if (existingFileIds.has(fileId))           { skipped++; continue; }

    const albumName = extractAndCleanAlbumName(audio.file_name, performer);
    const album     = albumMap.get(albumName.toLowerCase());
    if (!album) { console.warn(`⚠️  [Music] No album for "${albumName}"`); skipped++; continue; }

    const titleKey = `${title.toLowerCase()}::${album.id}`;
    if (existingTitleAlbum.has(titleKey))       { skipped++; continue; }

    // Track number: use TR## if available, else auto-increment
    const trackMatch = audio.file_name?.match(/TR(\d+)/i);
    let trackNum     = trackMatch ? parseInt(trackMatch[1]) : null;
    if (trackNum !== null && pendingTrackMap.has(`${album.id}::${trackNum}`)) trackNum = null;
    if (trackNum === null) {
      const dbMax  = maxTrackMap.get(album.id) || 0;
      const penMax = pendingTrackMap.get(`${album.id}::__max`) || 0;
      trackNum     = Math.max(dbMax, penMax) + 1;
    }
    pendingTrackMap.set(`${album.id}::${trackNum}`, true);
    pendingTrackMap.set(`${album.id}::__max`, Math.max(pendingTrackMap.get(`${album.id}::__max`) || 0, trackNum));
    existingFileIds.add(fileId);
    existingTitleAlbum.add(titleKey);

    songsToCreate.push({ albumId: album.id, trackNumber: trackNum, title, telegramFileId: fileId, duration, partCount: 1 });
  }

  if (songsToCreate.length > 0) {
    await prisma.song.createMany({ data: songsToCreate, skipDuplicates: true });
    console.log(`🎵 [Music] Inserted ${songsToCreate.length} songs, skipped ${skipped}`);
  }

  await saveState({ musicLastMsgId: highestMsgId });
  return { created: songsToCreate.length, skipped, scanned: rawMessages.length };
}

// ─────────────────────────────────────────────────────────────────────────────
// COVERS SYNC LOGIC
// ─────────────────────────────────────────────────────────────────────────────
async function runCoversSync() {
  const state     = await readState();
  const fromMsgId = (state.coversLastMsgId || 0) + 1;
  const channelId = process.env.TELEGRAM_COVERS_CHANNEL_ID;

  console.log(`📡 [Covers] Fetching from message ID ${fromMsgId}…`);
  const rawMessages = await fetchChannelMessages(channelId, fromMsgId);
  console.log(`📦 [Covers] ${rawMessages.length} forwarded messages received`);

  let highestMsgId = state.coversLastMsgId || 0;
  for (const m of rawMessages) {
    const origId = getOriginalMsgId(m);
    if (origId > highestMsgId) highestMsgId = origId;
  }

  const photoMessages = rawMessages.filter(m => m.photo);
  console.log(`🖼️  [Covers] ${photoMessages.length} photo messages`);

  // Save state even when no photos to prevent infinite re-scan
  if (photoMessages.length === 0) {
    await saveState({ coversLastMsgId: highestMsgId });
    return { updated: 0, scanned: rawMessages.length };
  }

  const [allAlbums, allSeries] = await Promise.all([
    prisma.album.findMany({ select: { id: true, title: true } }),
    prisma.series.findMany({ select: { id: true, title: true } }),
  ]);
  const albumMap  = new Map(allAlbums.map(a => [a.title.toLowerCase(), a]));
  const seriesMap = new Map(allSeries.map(s => [s.title.toLowerCase(), s]));

  const albumUpdates  = [];
  const seriesUpdates = [];

  for (const msg of photoMessages) {
    const caption = msg.caption || msg.forward_origin?.caption || '';
    const fileId  = msg.photo[msg.photo.length - 1].file_id;

    const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
    const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

    if (albumMatch) {
      const name  = albumMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
      const album = albumMap.get(name) ?? [...albumMap.values()].find(a => a.title.toLowerCase().includes(name));
      if (album)  { albumUpdates.push({ id: album.id, fileId }); console.log(`🖼️  Album: ${album.title}`); }
      else          console.warn(`⚠️  [Covers] No album for: "${name}"`);
    }

    if (seriesMatch) {
      const name   = seriesMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
      const series = seriesMap.get(name) ?? [...seriesMap.values()].find(s => s.title.toLowerCase().includes(name));
      if (series) { seriesUpdates.push({ id: series.id, fileId }); console.log(`🖼️  Series: ${series.title}`); }
      else          console.warn(`⚠️  [Covers] No series for: "${name}"`);
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
  return { updated: albumUpdates.length + seriesUpdates.length, scanned: rawMessages.length };
}

// ─────────────────────────────────────────────────────────────────────────────
// ROUTES
// ─────────────────────────────────────────────────────────────────────────────
router.post('/music', (req, res) => {
  if (syncStatus.music.running)
    return res.status(409).json({ message: 'Music sync already running — poll /api/sync/status' });

  res.status(202).json({ message: 'Music sync started. Poll GET /api/sync/status for result.' });
  syncStatus.music = { ...syncStatus.music, running: true, lastError: null, lastRun: new Date().toISOString() };

  runMusicSync()
    .then(r  => { syncStatus.music.lastResult = r;         console.log('✅ [Music] done:', r); })
    .catch(e => { syncStatus.music.lastError  = e.message; console.error('❌ [Music]', e.message); })
    .finally(() => { syncStatus.music.running = false; });
});

router.post('/covers', (req, res) => {
  if (syncStatus.covers.running)
    return res.status(409).json({ message: 'Covers sync already running — poll /api/sync/status' });

  res.status(202).json({ message: 'Covers sync started. Poll GET /api/sync/status for result.' });
  syncStatus.covers = { ...syncStatus.covers, running: true, lastError: null, lastRun: new Date().toISOString() };

  runCoversSync()
    .then(r  => { syncStatus.covers.lastResult = r;         console.log('✅ [Covers] done:', r); })
    .catch(e => { syncStatus.covers.lastError  = e.message; console.error('❌ [Covers]', e.message); })
    .finally(() => { syncStatus.covers.running = false; });
});

router.get('/status', async (req, res) => {
  const state = await readState();
  res.json({ music: syncStatus.music, covers: syncStatus.covers, state });
});

router.post('/reset', async (req, res) => {
  try {
    await saveState({ musicLastMsgId: 0, coversLastMsgId: 0 });
    syncStatus.music.lastResult  = null;
    syncStatus.covers.lastResult = null;
    res.json({ message: 'State reset. Next sync reads all messages from the beginning.' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;