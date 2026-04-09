// routes/sync.js
// Syncs music, audio stories, and cover images from Telegram channels into the DB.
//
// HOW IT WORKS
//  Uses getUpdates to replay channel post updates the bot received, and upserts
//  any songs, episodes, or covers that are missing from the DB.
//  No dump chat needed — the bot reads directly from its own update queue.
//
// STATE
//  The last-seen Telegram update_id cursor is stored in SyncState so it
//  survives Render deploys (Render resets the container filesystem on deploy).
//
// CONCURRENCY
//  Each sync type is guarded by a running flag. A 409 is returned if a sync
//  is already in progress.

const express = require('express');
const router  = express.Router();
const axios   = require('axios');
const prisma  = require('../services/db');

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

const MUSIC_CHANNEL_ID   = process.env.TELEGRAM_MUSIC_CHANNEL_ID;
const STORIES_CHANNEL_ID = process.env.TELEGRAM_STORIES_CHANNEL_ID;
const COVERS_CHANNEL_ID  = process.env.TELEGRAM_COVERS_CHANNEL_ID;

// ── Startup validation ────────────────────────────────────────────────────────
for (const key of ['TELEGRAM_BOT_TOKEN', 'TELEGRAM_MUSIC_CHANNEL_ID', 'TELEGRAM_STORIES_CHANNEL_ID', 'TELEGRAM_COVERS_CHANNEL_ID']) {
  if (!process.env[key]) console.error(`❌ Missing env var: ${key}`);
}

// ── State helpers (DB-backed, memory fallback) ────────────────────────────────
let memState = { musicLastUpdateId: 0, storiesLastUpdateId: 0, coversLastUpdateId: 0 };

async function readState() {
  try {
    const rows  = await prisma.syncState.findMany();
    const state = { musicLastUpdateId: 0, storiesLastUpdateId: 0, coversLastUpdateId: 0 };
    for (const row of rows) {
      if (row.key === 'musicLastUpdateId')   state.musicLastUpdateId   = parseInt(row.value) || 0;
      if (row.key === 'storiesLastUpdateId') state.storiesLastUpdateId = parseInt(row.value) || 0;
      if (row.key === 'coversLastUpdateId')  state.coversLastUpdateId  = parseInt(row.value) || 0;
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

// ── In-memory sync status ─────────────────────────────────────────────────────
const syncStatus = {
  music:   { running: false, lastResult: null, lastError: null, lastRun: null },
  stories: { running: false, lastResult: null, lastError: null, lastRun: null },
  covers:  { running: false, lastResult: null, lastError: null, lastRun: null },
};

// ── fetchUpdates ──────────────────────────────────────────────────────────────
// Fetches all pending bot updates (channel posts) from a given update_id offset.
// Telegram getUpdates returns up to 100 updates per call.
// We filter to only updates from the target channel.
async function fetchUpdates(channelId, fromUpdateId = 0) {
  const messages = [];
  let   offset   = fromUpdateId > 0 ? fromUpdateId + 1 : 0;

  while (true) {
    let updates = [];
    try {
      const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
        params: {
          offset,
          limit:            100,
          timeout:          0,
          allowed_updates:  ['channel_post'],
        },
      });
      updates = res.data.result || [];
    } catch (err) {
      console.error('❌ getUpdates error:', err.message);
      break;
    }

    if (updates.length === 0) break;

    for (const update of updates) {
      const post = update.channel_post;
      // Normalize channel ID comparison (Telegram returns numbers, env has strings)
      if (post && String(post.chat.id) === String(channelId)) {
        messages.push({ update_id: update.update_id, ...post });
      }
      offset = update.update_id + 1;
    }

    // Fewer than 100 means we've caught up
    if (updates.length < 100) break;

    await new Promise((r) => setTimeout(r, 200));
  }

  return { messages, lastUpdateId: offset - 1 };
}

// ── Album name cleaner ────────────────────────────────────────────────────────
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
  const state       = await readState();
  const fromUpdateId = state.musicLastUpdateId || 0;

  console.log(`📡 [Music] Fetching updates from offset ${fromUpdateId}…`);
  const { messages: raw, lastUpdateId } = await fetchUpdates(MUSIC_CHANNEL_ID, fromUpdateId);
  console.log(`📦 [Music] ${raw.length} channel posts received`);

  const audioPosts = raw.filter((m) => m.audio != null);
  console.log(`🎵 [Music] ${audioPosts.length} audio messages`);

  if (audioPosts.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ musicLastUpdateId: lastUpdateId });
    return { created: 0, skipped: 0, scanned: raw.length };
  }

  // Pre-load for deduplication
  const existingAlbums = await prisma.album.findMany({ select: { id: true, title: true } });
  const albumMap       = new Map(existingAlbums.map((a) => [a.title.toLowerCase(), a]));

  const existingSongs  = await prisma.song.findMany({ select: { telegramFileId: true, title: true, albumId: true } });
  const seenFileIds    = new Set(existingSongs.map((s) => s.telegramFileId).filter(Boolean));
  const seenTitleAlbum = new Set(existingSongs.map((s) => `${s.title.toLowerCase()}::${s.albumId}`));

  // Determine which albums need to be created
  const albumsToCreate = new Map();
  for (const msg of audioPosts) {
    const a   = msg.audio;
    const name = cleanAlbumName(a.file_name, a.performer);
    const key  = name.toLowerCase();
    if (!albumMap.has(key) && !albumsToCreate.has(key)) {
      albumsToCreate.set(key, { title: name, artist: a.performer || null });
    }
  }

  if (albumsToCreate.size > 0) {
    await prisma.album.createMany({ data: [...albumsToCreate.values()], skipDuplicates: true });
    console.log(`✅ [Music] Created ${albumsToCreate.size} album(s)`);
    const fresh = await prisma.album.findMany({ select: { id: true, title: true } });
    fresh.forEach((a) => albumMap.set(a.title.toLowerCase(), a));
  }

  // Track-number helpers
  const trackAgg    = await prisma.song.groupBy({ by: ['albumId'], _max: { trackNumber: true } });
  const maxTrackMap = new Map(trackAgg.map((r) => [r.albumId, r._max.trackNumber || 0]));
  const sessionMax  = new Map();

  const songsToCreate = [];
  let skipped = 0;

  for (const msg of audioPosts) {
    const audio     = msg.audio;
    const title     = audio.title || audio.file_name || 'Unknown';
    const performer = audio.performer || null;
    const fileId    = audio.file_id;
    const duration  = audio.duration ?? null;

    if (seenFileIds.has(fileId)) { skipped++; continue; }

    const albumName = cleanAlbumName(audio.file_name, performer);
    const album     = albumMap.get(albumName.toLowerCase());
    if (!album) { console.warn(`⚠️  [Music] No album matched for "${albumName}"`); skipped++; continue; }

    const titleKey = `${title.toLowerCase()}::${album.id}`;
    if (seenTitleAlbum.has(titleKey)) { skipped++; continue; }

    const trMatch  = audio.file_name?.match(/TR(\d+)/i);
    let   trackNum = trMatch ? parseInt(trMatch[1]) : null;

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

  if (lastUpdateId > fromUpdateId) await saveState({ musicLastUpdateId: lastUpdateId });
  return { created: songsToCreate.length, skipped, scanned: raw.length };
}

// ── runStoriesSync ────────────────────────────────────────────────────────────
async function runStoriesSync() {
  const state        = await readState();
  const fromUpdateId = state.storiesLastUpdateId || 0;

  console.log(`📡 [Stories] Fetching updates from offset ${fromUpdateId}…`);
  const { messages: raw, lastUpdateId } = await fetchUpdates(STORIES_CHANNEL_ID, fromUpdateId);
  console.log(`📦 [Stories] ${raw.length} channel posts received`);

  const audioPosts = raw.filter((m) => m.audio != null);
  console.log(`🎙️  [Stories] ${audioPosts.length} audio messages`);

  if (audioPosts.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });
    return { created: 0, skipped: 0, scanned: raw.length };
  }

  const allSeries  = await prisma.series.findMany({ select: { id: true, title: true } });
  const seriesMap  = new Map(allSeries.map((s) => [s.title.toLowerCase(), s]));

  const existingEpisodes = await prisma.episode.findMany({ select: { telegramFileId: true, seriesId: true, episodeNumber: true } });
  const seenFileIds      = new Set(existingEpisodes.map((e) => e.telegramFileId).filter(Boolean));
  const seenEpKeys       = new Set(existingEpisodes.map((e) => `${e.seriesId}::${e.episodeNumber}`));

  const episodesToCreate = [];
  let skipped = 0;

  for (const msg of audioPosts) {
    const audio   = msg.audio;
    const fileId  = audio.file_id;
    const caption = msg.caption || '';

    if (seenFileIds.has(fileId)) { skipped++; continue; }

    // Caption format expected: "Series Title — EP1: Episode Title"
    // or filename: SeriesTitle_EP01_EpisodeTitle.m4a
    const captionMatch  = caption.match(/^(.+?)\s*[—\-]+\s*EP(\d+)[:\s]+(.+)$/i);
    const fileNameMatch = audio.file_name?.match(/^(.+?)_EP(\d+)[_\s]+(.+?)\./i);
    const match         = captionMatch || fileNameMatch;

    if (!match) {
      console.warn(`⚠️  [Stories] Cannot parse series/episode from: "${caption || audio.file_name}"`);
      skipped++;
      continue;
    }

    const seriesTitle  = match[1].trim();
    const episodeNum   = parseInt(match[2]);
    const episodeTitle = match[3].trim();

    // Find or create series
    let series = seriesMap.get(seriesTitle.toLowerCase());
    if (!series) {
      series = await prisma.series.create({ data: { title: seriesTitle } });
      seriesMap.set(seriesTitle.toLowerCase(), series);
      console.log(`📚 [Stories] Created series: "${seriesTitle}"`);
    }

    const epKey = `${series.id}::${episodeNum}`;
    if (seenEpKeys.has(epKey)) { skipped++; continue; }

    seenFileIds.add(fileId);
    seenEpKeys.add(epKey);

    episodesToCreate.push({
      seriesId:       series.id,
      episodeNumber:  episodeNum,
      title:          episodeTitle,
      telegramFileId: fileId,
      duration:       audio.duration ?? null,
      partCount:      1,
    });
  }

  if (episodesToCreate.length > 0) {
    await prisma.episode.createMany({ data: episodesToCreate, skipDuplicates: true });
    console.log(`🎙️  [Stories] Inserted ${episodesToCreate.length} episodes, skipped ${skipped}`);
  }

  if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });
  return { created: episodesToCreate.length, skipped, scanned: raw.length };
}

// ── runCoversSync ─────────────────────────────────────────────────────────────
async function runCoversSync() {
  const state        = await readState();
  const fromUpdateId = state.coversLastUpdateId || 0;

  console.log(`📡 [Covers] Fetching updates from offset ${fromUpdateId}…`);
  const { messages: raw, lastUpdateId } = await fetchUpdates(COVERS_CHANNEL_ID, fromUpdateId);
  console.log(`📦 [Covers] ${raw.length} channel posts received`);

  const photoMessages = raw.filter((m) => m.photo);
  console.log(`🖼️  [Covers] ${photoMessages.length} photo messages`);

  if (photoMessages.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ coversLastUpdateId: lastUpdateId });
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
    const caption = msg.caption || '';
    const fileId  = msg.photo[msg.photo.length - 1].file_id; // highest resolution

    const albumMatch  = caption.match(/COVER_ALBUM:(.+)/i);
    const seriesMatch = caption.match(/COVER_SERIES:(.+)/i);

    if (albumMatch) {
      const name  = albumMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
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

  if (lastUpdateId > fromUpdateId) await saveState({ coversLastUpdateId: lastUpdateId });
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

// POST /api/sync/stories
router.post('/stories', (req, res) => {
  if (syncStatus.stories.running)
    return res.status(409).json({ message: 'Stories sync already running — poll GET /api/sync/status' });

  syncStatus.stories = { ...syncStatus.stories, running: true, lastError: null, lastRun: new Date().toISOString() };
  res.status(202).json({ message: 'Stories sync started. Poll GET /api/sync/status for result.' });

  runStoriesSync()
    .then((r)  => { syncStatus.stories.lastResult = r; console.log('✅ [Stories] sync done:', r); })
    .catch((e) => { syncStatus.stories.lastError  = e.message; console.error('❌ [Stories]', e.message); })
    .finally(() => { syncStatus.stories.running = false; });
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
    res.json({ success: true, data: { music: syncStatus.music, stories: syncStatus.stories, covers: syncStatus.covers, state } });
  } catch (err) { next(err); }
});

// POST /api/sync/reset — re-scans everything from the beginning
router.post('/reset', async (req, res, next) => {
  try {
    await saveState({ musicLastUpdateId: 0, storiesLastUpdateId: 0, coversLastUpdateId: 0 });
    syncStatus.music.lastResult   = null;
    syncStatus.stories.lastResult = null;
    syncStatus.covers.lastResult  = null;
    res.json({ success: true, message: 'Sync state reset. Next run will fetch all updates from the beginning.' });
  } catch (err) { next(err); }
});

module.exports = router;