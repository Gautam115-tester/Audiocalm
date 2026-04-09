// routes/sync.js
const express = require('express');
const router  = express.Router();
const axios   = require('axios');
const prisma  = require('../services/db');
const fs      = require('fs');
const path    = require('path');

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

// ─────────────────────────────────────────────────────────────────────────────
// STATE FILE — tracks last processed message_id per channel
// ─────────────────────────────────────────────────────────────────────────────
const STATE_FILE = path.join(__dirname, '../.sync_state.json');

function readState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return { musicLastMsgId: 0, coversLastMsgId: 0 };
  }
}

function saveState(patch) {
  const state = readState();
  fs.writeFileSync(STATE_FILE, JSON.stringify({ ...state, ...patch }), 'utf8');
}

// ─────────────────────────────────────────────────────────────────────────────
// SYNC STATUS — lets the dashboard poll for background job results
// ─────────────────────────────────────────────────────────────────────────────
const syncStatus = {
  music:  { running: false, lastResult: null, lastError: null, lastRun: null },
  covers: { running: false, lastResult: null, lastError: null, lastRun: null },
};

// ─────────────────────────────────────────────────────────────────────────────
// FETCH CHANNEL MESSAGES via forwardMessages
//
// Telegram doesn't expose getChatHistory for bots, but forwardMessages lets us
// forward any message_id range to a dump chat and read the forwarded metadata.
//
// FIX 1: Use forward_origin.message_id (not forward_from_message_id) to get
//         the original channel message ID from a forwarded message.
// FIX 2: Increase consecutiveEmpty threshold to 5 to handle sparse channels
//         where message IDs have large gaps (deleted messages, polls, stickers).
// ─────────────────────────────────────────────────────────────────────────────
const BATCH_SIZE = 100; // Telegram max for forwardMessages

async function fetchChannelMessages(channelId, fromMsgId = 1) {
  const DUMP_CHAT = process.env.TELEGRAM_DUMP_CHAT_ID;
  if (!DUMP_CHAT) {
    throw new Error('TELEGRAM_DUMP_CHAT_ID is not set in .env');
  }

  const messages = [];
  let currentId = fromMsgId;
  let consecutiveEmpty = 0;
  const MAX_EMPTY = 5; // FIX 2: was 3, raised to handle ID gaps

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
      // 400 = ALL message IDs in batch don't exist → past end of channel
      if (err.response?.status === 400) break;
      throw err;
    }

    if (forwarded.length === 0) {
      consecutiveEmpty++;
      currentId += BATCH_SIZE;
      continue;
    }

    consecutiveEmpty = 0;
    messages.push(...forwarded);
    currentId += BATCH_SIZE;

    // Respect Telegram rate limits
    await new Promise(r => setTimeout(r, 400));
  }

  return messages;
}

// ─────────────────────────────────────────────────────────────────────────────
// GET ORIGINAL MESSAGE ID from a forwarded message
//
// FIX 1: Telegram puts the original channel message_id in forward_origin.message_id
//         NOT in forward_from_message_id (that field is for user-forwarded messages).
// ─────────────────────────────────────────────────────────────────────────────
function getOriginalMsgId(forwardedMsg) {
  return (
    forwardedMsg?.forward_origin?.message_id || // ✅ correct field for channel forwards
    forwardedMsg?.forward_from_message_id    || // fallback (user forwards)
    forwardedMsg?.message_id                    // last resort: use the dump chat msg id
  );
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
// MUSIC SYNC LOGIC (runs in background)
// ─────────────────────────────────────────────────────────────────────────────
async function runMusicSync() {
  const state     = readState();
  const fromMsgId = (state.musicLastMsgId || 0) + 1;
  const channelId = process.env.TELEGRAM_MUSIC_CHANNEL_ID;

  console.log(`📡 [Music] Fetching from message ID ${fromMsgId}…`);
  const rawMessages = await fetchChannelMessages(channelId, fromMsgId);
  console.log(`📦 [Music] Got ${rawMessages.length} forwarded messages total`);

  // FIX 3: Removed the dead duplicate `audioMessages` variable — only keep audioPosts
  const audioPosts = rawMessages.filter(m => m.audio != null);
  console.log(`🎵 [Music] ${audioPosts.length} are audio messages`);

  // Track highest original message_id — FIX 1 applied here
  let highestMsgId = state.musicLastMsgId || 0;
  for (const m of rawMessages) {
    const origId = getOriginalMsgId(m);
    if (origId > highestMsgId) highestMsgId = origId;
  }

  // Always save state even if no audio found, so we don't re-scan same IDs
  // FIX 4: was only saving state at the end, now save immediately after scan
  if (audioPosts.length === 0) {
    saveState({ musicLastMsgId: highestMsgId });
    return { created: 0, skipped: 0, scanned: rawMessages.length };
  }

  // ── Pre-load albums ─────────────────────────────────────────────────────────
  const existingAlbums = await prisma.album.findMany({ select: { id: true, title: true } });
  const albumMap = new Map(existingAlbums.map(a => [a.title.toLowerCase(), a]));

  // ── Pre-load songs ──────────────────────────────────────────────────────────
  const existingSongs = await prisma.song.findMany({
    select: { telegramFileId: true, title: true, albumId: true },
  });
  const existingFileIds    = new Set(existingSongs.map(s => s.telegramFileId).filter(Boolean));
  const existingTitleAlbum = new Set(existingSongs.map(s => `${s.title.toLowerCase()}::${s.albumId}`));

  // ── Collect new albums ──────────────────────────────────────────────────────
  const albumsToCreate = new Map();
  for (const msg of audioPosts) {
    const audio     = msg.audio;
    const performer = audio.performer || 'Unknown';
    const albumName = extractAndCleanAlbumName(audio.file_name, performer);
    const key       = albumName.toLowerCase();
    if (!albumMap.has(key) && !albumsToCreate.has(key)) {
      albumsToCreate.set(key, { title: albumName, artist: performer });
    }
  }

  if (albumsToCreate.size > 0) {
    await prisma.album.createMany({ data: [...albumsToCreate.values()], skipDuplicates: true });
    console.log(`✅ [Music] Created ${albumsToCreate.size} new album(s)`);
    const fresh = await prisma.album.findMany({ select: { id: true, title: true } });
    fresh.forEach(a => albumMap.set(a.title.toLowerCase(), a));
  }

  // ── Pre-load max track numbers ───────────────────────────────────────────────
  const trackAgg     = await prisma.song.groupBy({ by: ['albumId'], _max: { trackNumber: true } });
  const maxTrackMap  = new Map(trackAgg.map(r => [r.albumId, r._max.trackNumber || 0]));
  const pendingTrackMap = new Map();

  // ── Build songs to insert ────────────────────────────────────────────────────
  const songsToCreate = [];
  let skipped = 0;

  for (const msg of audioPosts) {
    const audio     = msg.audio;
    const title     = audio.title || audio.file_name || 'Unknown';
    const performer = audio.performer || 'Unknown';
    const fileId    = audio.file_id;
    const duration  = audio.duration;

    // Dedup layer 1: same file_id
    if (existingFileIds.has(fileId)) { skipped++; continue; }

    const albumName = extractAndCleanAlbumName(audio.file_name, performer);
    const album     = albumMap.get(albumName.toLowerCase());
    if (!album) {
      console.warn(`⚠️  [Music] No album found for "${albumName}" — skipping`);
      skipped++;
      continue;
    }

    // Dedup layer 2: same title + album
    const titleKey = `${title.toLowerCase()}::${album.id}`;
    if (existingTitleAlbum.has(titleKey)) { skipped++; continue; }

    // Track number: prefer TR## from filename, else auto-increment
    const trackMatch = audio.file_name?.match(/TR(\d+)/i);
    let   trackNum   = trackMatch ? parseInt(trackMatch[1]) : null;
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

    songsToCreate.push({
      albumId:        album.id,
      trackNumber:    trackNum,
      title,
      telegramFileId: fileId,
      duration,
      partCount:      1,
    });
  }

  if (songsToCreate.length > 0) {
    await prisma.song.createMany({ data: songsToCreate, skipDuplicates: true });
    console.log(`🎵 [Music] Inserted ${songsToCreate.length} songs, skipped ${skipped}`);
  }

  saveState({ musicLastMsgId: highestMsgId });
  return { created: songsToCreate.length, skipped, scanned: rawMessages.length };
}

// ─────────────────────────────────────────────────────────────────────────────
// COVERS SYNC LOGIC (runs in background)
// ─────────────────────────────────────────────────────────────────────────────
async function runCoversSync() {
  const state     = readState();
  const fromMsgId = (state.coversLastMsgId || 0) + 1;
  const channelId = process.env.TELEGRAM_COVERS_CHANNEL_ID;

  console.log(`📡 [Covers] Fetching from message ID ${fromMsgId}…`);
  const rawMessages = await fetchChannelMessages(channelId, fromMsgId);
  console.log(`📦 [Covers] Got ${rawMessages.length} forwarded messages total`);

  // FIX 4: Always track & save highestMsgId even when no photos found
  let highestMsgId = state.coversLastMsgId || 0;
  for (const m of rawMessages) {
    const origId = getOriginalMsgId(m); // FIX 1 applied here too
    if (origId > highestMsgId) highestMsgId = origId;
  }

  const photoMessages = rawMessages.filter(m => m.photo);
  console.log(`🖼️  [Covers] ${photoMessages.length} are photo messages`);

  if (photoMessages.length === 0) {
    saveState({ coversLastMsgId: highestMsgId }); // FIX 4: was missing — caused infinite re-scan
    return { updated: 0, scanned: rawMessages.length };
  }

  const [allAlbums, allSeries] = await Promise.all([
    prisma.album.findMany({ select: { id: true, title: true } }),
    prisma.series.findMany({ select: { id: true, title: true } }),
  ]);
  const albumMap  = new Map(allAlbums.map(a  => [a.title.toLowerCase(), a]));
  const seriesMap = new Map(allSeries.map(s  => [s.title.toLowerCase(), s]));

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
      if (album) {
        albumUpdates.push({ id: album.id, fileId });
        console.log(`🖼️  [Covers] Matched album cover: ${album.title}`);
      } else {
        console.warn(`⚠️  [Covers] No album matched for caption: "${name}"`);
      }
    }

    if (seriesMatch) {
      const name   = seriesMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
      const series = seriesMap.get(name) ?? [...seriesMap.values()].find(s => s.title.toLowerCase().includes(name));
      if (series) {
        seriesUpdates.push({ id: series.id, fileId });
        console.log(`🖼️  [Covers] Matched series cover: ${series.title}`);
      } else {
        console.warn(`⚠️  [Covers] No series matched for caption: "${name}"`);
      }
    }
  }

  await Promise.all([
    ...albumUpdates.map(  ({ id, fileId }) => prisma.album.update( { where: { id }, data: { coverTelegramFileId: fileId } })),
    ...seriesUpdates.map( ({ id, fileId }) => prisma.series.update({ where: { id }, data: { coverTelegramFileId: fileId } })),
  ]);

  saveState({ coversLastMsgId: highestMsgId });
  return { updated: albumUpdates.length + seriesUpdates.length, scanned: rawMessages.length };
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/music
// Responds immediately with 202, runs sync in background
// Poll GET /api/sync/status to see result
// ─────────────────────────────────────────────────────────────────────────────
router.post('/music', (req, res) => {
  if (syncStatus.music.running) {
    return res.status(409).json({ message: 'Music sync already running — check /api/sync/status' });
  }

  // FIX 5: Respond immediately so Render's 30s timeout doesn't kill the request
  res.status(202).json({ message: 'Music sync started in background. Poll GET /api/sync/status for result.' });

  syncStatus.music.running   = true;
  syncStatus.music.lastError = null;
  syncStatus.music.lastRun   = new Date().toISOString();

  runMusicSync()
    .then(result => {
      syncStatus.music.lastResult = result;
      console.log(`✅ [Music] Sync complete:`, result);
    })
    .catch(err => {
      syncStatus.music.lastError = err.message;
      console.error(`❌ [Music] Sync failed:`, err.message);
    })
    .finally(() => {
      syncStatus.music.running = false;
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/covers
// ─────────────────────────────────────────────────────────────────────────────
router.post('/covers', (req, res) => {
  if (syncStatus.covers.running) {
    return res.status(409).json({ message: 'Covers sync already running — check /api/sync/status' });
  }

  res.status(202).json({ message: 'Covers sync started in background. Poll GET /api/sync/status for result.' });

  syncStatus.covers.running   = true;
  syncStatus.covers.lastError = null;
  syncStatus.covers.lastRun   = new Date().toISOString();

  runCoversSync()
    .then(result => {
      syncStatus.covers.lastResult = result;
      console.log(`✅ [Covers] Sync complete:`, result);
    })
    .catch(err => {
      syncStatus.covers.lastError = err.message;
      console.error(`❌ [Covers] Sync failed:`, err.message);
    })
    .finally(() => {
      syncStatus.covers.running = false;
    });
});

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/sync/status
// Check background sync progress
// ─────────────────────────────────────────────────────────────────────────────
router.get('/status', (req, res) => {
  res.json({
    music:  syncStatus.music,
    covers: syncStatus.covers,
    state:  readState(),
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/reset
// ─────────────────────────────────────────────────────────────────────────────
router.post('/reset', (req, res) => {
  try {
    saveState({ musicLastMsgId: 0, coversLastMsgId: 0 });
    res.json({ message: 'State reset. Next sync will read all messages from the beginning.' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

module.exports = router;