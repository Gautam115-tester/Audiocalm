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
// MESSAGE ID TRACKING
//
// We store the last processed message_id PER CHANNEL (not update_id).
// This is the key difference from the old approach:
//
// ❌ OLD: getUpdates (offset-based) — only works for recent 24hrs, destructive,
//         limited to 100 at a time, mixes all channels in one stream.
//
// ✅ NEW: forwardMessages (message_id-based) — works on ALL historical messages,
//         non-destructive (reading doesn't delete anything), channels are
//         independent, fetches as far back as message_id=1.
//
// We forward messages to a private "dump" chat (your own bot's private chat or
// a private group) and inspect the forwarded content. This is the only way
// to read full channel history with a bot token.
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
// FETCH CHANNEL MESSAGES — reads ALL messages from a channel using
// forwardMessages to a dump chat, starting from (lastMsgId + 1).
//
// HOW IT WORKS:
//   Telegram Bot API doesn't expose getChatHistory directly, but we can use
//   forwardMessages to forward a range of message IDs to any chat the bot
//   can write to. Forwarded messages come back as normal messages with full
//   audio/photo metadata intact.
//
// SETUP NEEDED:
//   Set TELEGRAM_DUMP_CHAT_ID in your .env to any chat your bot can send to.
//   The easiest option: send /start to your bot in DM, use your own user ID.
//   Or create a private group, add your bot, use that group's ID.
// ─────────────────────────────────────────────────────────────────────────────
const BATCH_SIZE = 100; // Telegram max for forwardMessages

async function fetchChannelMessages(channelId, fromMsgId = 1) {
  const DUMP_CHAT = process.env.TELEGRAM_DUMP_CHAT_ID;
  if (!DUMP_CHAT) {
    throw new Error('TELEGRAM_DUMP_CHAT_ID is not set in .env — see sync.js comments for setup instructions');
  }

  const messages = [];

  // We need to find the latest message_id in the channel first
  // by trying to forward a very high message_id and seeing what exists.
  // Simpler approach: forward batches from fromMsgId upward until we hit empty.

  let currentId = fromMsgId;
  let consecutiveEmpty = 0;

  while (consecutiveEmpty < 3) {
    // Build array of IDs to try: [currentId, currentId+1, ..., currentId+99]
    const msgIds = Array.from({ length: BATCH_SIZE }, (_, i) => currentId + i);

    let forwarded;
    try {
      const res = await axios.post(`${TELEGRAM_API}/forwardMessages`, {
        chat_id:     DUMP_CHAT,
        from_chat_id: channelId,
        message_ids: msgIds,
        disable_notification: true,
      });
      forwarded = res.data.result || [];
    } catch (err) {
      // Telegram returns 400 if ALL message IDs in the batch don't exist
      // This means we've gone past the end of the channel
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

    // Small delay to avoid hitting rate limits
    await new Promise(r => setTimeout(r, 300));
  }

  return messages;
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
// ─────────────────────────────────────────────────────────────────────────────
router.post('/music', async (req, res) => {
  try {
    const state      = readState();
    const fromMsgId  = (state.musicLastMsgId || 0) + 1;
    const channelId  = process.env.TELEGRAM_MUSIC_CHANNEL_ID;

    console.log(`📡 Fetching music channel messages from ID ${fromMsgId}…`);
    const rawMessages = await fetchChannelMessages(channelId, fromMsgId);

    // Filter to only audio messages
    const audioMessages = rawMessages.filter(m => m.audio || m.forward_origin?.message_id);

    // More accurately: forwarded messages keep the original audio field
    const audioPosts = rawMessages.filter(m => {
      // forwardMessages returns the forwarded message objects which have audio directly
      return m.audio != null;
    });

    if (audioPosts.length === 0) {
      return res.json({ message: 'Music sync complete — no new messages', created: 0, skipped: 0 });
    }

    console.log(`📥 Found ${audioPosts.length} audio messages`);

    // Track highest message_id seen in this batch
    let highestMsgId = state.musicLastMsgId || 0;
    for (const m of rawMessages) {
      // The forwarded message has forward_from_message_id
      const origId = m.forward_from_message_id || m.message_id;
      if (origId > highestMsgId) highestMsgId = origId;
    }

    // ── Pre-load albums ───────────────────────────────────────────────────────
    const existingAlbums = await prisma.album.findMany({ select: { id: true, title: true } });
    const albumMap = new Map(existingAlbums.map(a => [a.title.toLowerCase(), a]));

    // ── Pre-load songs ────────────────────────────────────────────────────────
    const existingSongs = await prisma.song.findMany({
      select: { telegramFileId: true, title: true, albumId: true },
    });
    const existingFileIds    = new Set(existingSongs.map(s => s.telegramFileId).filter(Boolean));
    const existingTitleAlbum = new Set(existingSongs.map(s => `${s.title.toLowerCase()}::${s.albumId}`));

    // ── Collect new albums ────────────────────────────────────────────────────
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
      console.log(`✅ Created ${albumsToCreate.size} new album(s)`);
      const fresh = await prisma.album.findMany({ select: { id: true, title: true } });
      fresh.forEach(a => albumMap.set(a.title.toLowerCase(), a));
    }

    // ── Pre-load max track numbers ────────────────────────────────────────────
    const trackAgg = await prisma.song.groupBy({ by: ['albumId'], _max: { trackNumber: true } });
    const maxTrackMap     = new Map(trackAgg.map(r => [r.albumId, r._max.trackNumber || 0]));
    const pendingTrackMap = new Map();

    // ── Build songs to insert ─────────────────────────────────────────────────
    const songsToCreate = [];
    let skipped = 0;

    for (const msg of audioPosts) {
      const audio     = msg.audio;
      const title     = audio.title || audio.file_name || 'Unknown';
      const performer = audio.performer || 'Unknown';
      const fileId    = audio.file_id;
      const duration  = audio.duration;

      // Layer-1: same file
      if (existingFileIds.has(fileId)) { skipped++; continue; }

      const albumName = extractAndCleanAlbumName(audio.file_name, performer);
      const album     = albumMap.get(albumName.toLowerCase());
      if (!album) { console.warn(`⚠️  No album for "${albumName}"`); skipped++; continue; }

      // Layer-2: same title + album
      const titleKey = `${title.toLowerCase()}::${album.id}`;
      if (existingTitleAlbum.has(titleKey)) { skipped++; continue; }

      // Track number
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

      songsToCreate.push({ albumId: album.id, trackNumber: trackNum, title, telegramFileId: fileId, duration, partCount: 1 });
    }

    // ── Bulk insert, then save state ──────────────────────────────────────────
    if (songsToCreate.length > 0) {
      await prisma.song.createMany({ data: songsToCreate, skipDuplicates: true });
      console.log(`🎵 Inserted ${songsToCreate.length} songs`);
    }

    // Save the highest original message_id we processed
    saveState({ musicLastMsgId: highestMsgId });

    res.json({ message: 'Music sync complete', created: songsToCreate.length, skipped });
  } catch (err) {
    console.error('Music sync error:', err.message);
    res.status(500).json({ error: 'Sync failed', message: err.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/covers
// ─────────────────────────────────────────────────────────────────────────────
router.post('/covers', async (req, res) => {
  try {
    const state     = readState();
    const fromMsgId = (state.coversLastMsgId || 0) + 1;
    const channelId = process.env.TELEGRAM_COVERS_CHANNEL_ID;

    console.log(`📡 Fetching covers channel messages from ID ${fromMsgId}…`);
    const rawMessages = await fetchChannelMessages(channelId, fromMsgId);

    const photoMessages = rawMessages.filter(m => m.photo);

    if (photoMessages.length === 0) {
      return res.json({ message: 'Covers sync complete — no new messages', updated: 0 });
    }

    let highestMsgId = state.coversLastMsgId || 0;
    for (const m of rawMessages) {
      const origId = m.forward_from_message_id || m.message_id;
      if (origId > highestMsgId) highestMsgId = origId;
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
        if (album) { albumUpdates.push({ id: album.id, fileId }); console.log(`🖼️  Album cover: ${album.title}`); }
        else console.warn(`⚠️  No album for cover: "${name}"`);
      }

      if (seriesMatch) {
        const name   = seriesMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
        const series = seriesMap.get(name) ?? [...seriesMap.values()].find(s => s.title.toLowerCase().includes(name));
        if (series) { seriesUpdates.push({ id: series.id, fileId }); console.log(`🖼️  Series cover: ${series.title}`); }
        else console.warn(`⚠️  No series for cover: "${name}"`);
      }
    }

    await Promise.all([
      ...albumUpdates.map( ({ id, fileId }) => prisma.album.update({ where: { id }, data: { coverTelegramFileId: fileId } })),
      ...seriesUpdates.map(({ id, fileId }) => prisma.series.update({ where: { id }, data: { coverTelegramFileId: fileId } })),
    ]);

    saveState({ coversLastMsgId: highestMsgId });

    res.json({ message: 'Covers sync complete', updated: albumUpdates.length + seriesUpdates.length });
  } catch (err) {
    console.error('Covers sync error:', err.message);
    res.status(500).json({ error: 'Covers sync failed', message: err.message });
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/sync/reset  — re-process everything from message_id 1
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