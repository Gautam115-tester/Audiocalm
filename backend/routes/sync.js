// routes/sync.js
// Syncs music, audio stories, and cover images from Telegram channels into the DB.
//
// FIX: Full pagination — fetches ALL updates across multiple getUpdates calls,
//      not just the first 100. Uses offset cursor stored in DB so nothing is missed.
//
// FIX: Routes now respond synchronously (200 with results) so the dashboard HTML
//      and Flutter app both receive created/updated counts immediately.

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
for (const key of [
  'TELEGRAM_BOT_TOKEN',
  'TELEGRAM_MUSIC_CHANNEL_ID',
  'TELEGRAM_STORIES_CHANNEL_ID',
  'TELEGRAM_COVERS_CHANNEL_ID',
]) {
  if (!process.env[key]) console.error(`❌ Missing env var: ${key}`);
}

// ── State helpers (DB-backed, memory fallback) ────────────────────────────────
let memState = {
  musicLastUpdateId:   0,
  storiesLastUpdateId: 0,
  coversLastUpdateId:  0,
};

async function readState() {
  try {
    const rows  = await prisma.syncState.findMany();
    const state = {
      musicLastUpdateId:   0,
      storiesLastUpdateId: 0,
      coversLastUpdateId:  0,
    };
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

// ── fetchAllUpdates ───────────────────────────────────────────────────────────
// Fetches EVERY pending update from Telegram for a given channel using full
// pagination. Telegram returns max 100 per call, so we loop with an increasing
// offset until we get fewer than 100 (meaning we've reached the end).
//
// Key fix: we do NOT break on the first batch; we keep calling until Telegram
// returns an empty result or fewer than 100 updates.
//
// @param {string|number} channelId  — the channel to filter posts for
// @param {number}        fromUpdateId — last seen update_id (0 = start from oldest)
// @returns {{ messages: object[], lastUpdateId: number }}
async function fetchAllUpdates(channelId, fromUpdateId = 0) {
  const messages      = [];
  let   offset        = fromUpdateId > 0 ? fromUpdateId + 1 : 0;
  let   totalFetched  = 0;
  let   pageNum       = 0;

  console.log(`  📡 Starting paginated fetch from offset ${offset} for channel ${channelId}`);

  while (true) {
    pageNum++;
    let updates = [];

    try {
      const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
        params: {
          offset,
          limit:           100,          // Telegram's hard maximum per call
          timeout:         0,            // long-poll disabled (we want immediate)
          allowed_updates: ['channel_post'],
        },
        timeout: 30_000,
      });
      updates = res.data.result || [];
    } catch (err) {
      const status = err.response?.status;
      const desc   = err.response?.data?.description || err.message;
      console.error(`  ❌ getUpdates page ${pageNum} error (HTTP ${status}): ${desc}`);
      // Don't break the whole sync on a transient error — return what we have
      break;
    }

    totalFetched += updates.length;
    console.log(`  📦 Page ${pageNum}: ${updates.length} updates (total so far: ${totalFetched})`);

    if (updates.length === 0) break; // nothing left in Telegram's queue

    for (const update of updates) {
      const post = update.channel_post;
      // Telegram returns channel IDs as negative numbers; env vars may be
      // stored as strings. Normalize both sides for a safe comparison.
      if (post && String(post.chat.id) === String(channelId)) {
        messages.push({ update_id: update.update_id, ...post });
      }
      // Always advance offset past every update we've seen, even non-matching ones,
      // otherwise we'll re-process them on the next sync run.
      offset = update.update_id + 1;
    }

    // Fewer than 100 means this was the last page
    if (updates.length < 100) break;

    // Brief pause between pages to be polite to the Telegram API
    await new Promise((r) => setTimeout(r, 300));
  }

  const lastUpdateId = offset - 1;
  console.log(
    `  ✅ Pagination complete: ${messages.length} matching posts across ${pageNum} page(s). ` +
    `Last update_id: ${lastUpdateId}`
  );

  return { messages, lastUpdateId };
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
  const state        = await readState();
  const fromUpdateId = state.musicLastUpdateId || 0;

  console.log(`\n🎵 [Music Sync] Starting — last update_id: ${fromUpdateId}`);

  const { messages: raw, lastUpdateId } = await fetchAllUpdates(MUSIC_CHANNEL_ID, fromUpdateId);
  console.log(`🎵 [Music] ${raw.length} channel posts received total`);

  const audioPosts = raw.filter((m) => m.audio != null);
  console.log(`🎵 [Music] ${audioPosts.length} audio messages to process`);

  if (audioPosts.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ musicLastUpdateId: lastUpdateId });
    return { created: 0, skipped: 0, scanned: raw.length, albums: 0 };
  }

  // ── Pre-load for deduplication ──────────────────────────────────────────────
  const existingAlbums = await prisma.album.findMany({ select: { id: true, title: true } });
  const albumMap       = new Map(existingAlbums.map((a) => [a.title.toLowerCase(), a]));

  const existingSongs  = await prisma.song.findMany({
    select: { telegramFileId: true, title: true, albumId: true },
  });
  const seenFileIds    = new Set(existingSongs.map((s) => s.telegramFileId).filter(Boolean));
  const seenTitleAlbum = new Set(existingSongs.map((s) => `${s.title.toLowerCase()}::${s.albumId}`));

  // ── Determine albums to create ──────────────────────────────────────────────
  const albumsToCreate = new Map();
  for (const msg of audioPosts) {
    const a    = msg.audio;
    const name = cleanAlbumName(a.file_name, a.performer);
    const key  = name.toLowerCase();
    if (!albumMap.has(key) && !albumsToCreate.has(key)) {
      albumsToCreate.set(key, { title: name, artist: a.performer || null });
    }
  }

  if (albumsToCreate.size > 0) {
    await prisma.album.createMany({
      data:           [...albumsToCreate.values()],
      skipDuplicates: true,
    });
    console.log(`✅ [Music] Created ${albumsToCreate.size} new album(s)`);
    const fresh = await prisma.album.findMany({ select: { id: true, title: true } });
    fresh.forEach((a) => albumMap.set(a.title.toLowerCase(), a));
  }

  // ── Track-number helpers ────────────────────────────────────────────────────
  const trackAgg    = await prisma.song.groupBy({ by: ['albumId'], _max: { trackNumber: true } });
  const maxTrackMap = new Map(trackAgg.map((r) => [r.albumId, r._max.trackNumber || 0]));
  const sessionMax  = new Map(); // tracks numbers assigned this run

  const songsToCreate = [];
  let   skipped       = 0;

  for (const msg of audioPosts) {
    const audio     = msg.audio;
    const title     = audio.title || audio.file_name || 'Unknown';
    const performer = audio.performer || null;
    const fileId    = audio.file_id;
    const duration  = audio.duration ?? null;

    // Skip if we've already stored this exact file
    if (seenFileIds.has(fileId)) { skipped++; continue; }

    const albumName = cleanAlbumName(audio.file_name, performer);
    const album     = albumMap.get(albumName.toLowerCase());
    if (!album) {
      console.warn(`⚠️  [Music] No album matched for "${albumName}" — skipping`);
      skipped++;
      continue;
    }

    // Skip if this title already exists in the same album
    const titleKey = `${title.toLowerCase()}::${album.id}`;
    if (seenTitleAlbum.has(titleKey)) { skipped++; continue; }

    // Determine track number (from filename TR01 pattern or auto-increment)
    const trMatch  = audio.file_name?.match(/TR(\d+)/i);
    let   trackNum = trMatch ? parseInt(trMatch[1]) : null;

    if (trackNum !== null && sessionMax.has(`${album.id}::${trackNum}`)) {
      trackNum = null; // collision within this sync run — fall through to auto
    }

    if (trackNum === null) {
      const dbMax  = maxTrackMap.get(album.id) || 0;
      const sesMax = sessionMax.get(`${album.id}::__max`) || 0;
      trackNum     = Math.max(dbMax, sesMax) + 1;
    }

    sessionMax.set(`${album.id}::${trackNum}`, true);
    sessionMax.set(
      `${album.id}::__max`,
      Math.max(sessionMax.get(`${album.id}::__max`) || 0, trackNum)
    );
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
    // Insert in batches of 100 to avoid hitting Prisma/DB limits
    const BATCH = 100;
    for (let i = 0; i < songsToCreate.length; i += BATCH) {
      await prisma.song.createMany({
        data:           songsToCreate.slice(i, i + BATCH),
        skipDuplicates: true,
      });
    }
    console.log(`🎵 [Music] Inserted ${songsToCreate.length} songs, skipped ${skipped}`);
  }

  if (lastUpdateId > fromUpdateId) await saveState({ musicLastUpdateId: lastUpdateId });

  return {
    created:  songsToCreate.length,
    skipped,
    scanned:  raw.length,
    albums:   albumMap.size,
  };
}

// ── runStoriesSync ────────────────────────────────────────────────────────────
async function runStoriesSync() {
  const state        = await readState();
  const fromUpdateId = state.storiesLastUpdateId || 0;

  console.log(`\n🎙️  [Stories Sync] Starting — last update_id: ${fromUpdateId}`);

  const { messages: raw, lastUpdateId } = await fetchAllUpdates(STORIES_CHANNEL_ID, fromUpdateId);
  console.log(`🎙️  [Stories] ${raw.length} channel posts received total`);

  const audioPosts = raw.filter((m) => m.audio != null);
  console.log(`🎙️  [Stories] ${audioPosts.length} audio messages to process`);

  if (audioPosts.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });
    return { created: 0, skipped: 0, scanned: raw.length };
  }

  const allSeries  = await prisma.series.findMany({ select: { id: true, title: true } });
  const seriesMap  = new Map(allSeries.map((s) => [s.title.toLowerCase(), s]));

  const existingEpisodes = await prisma.episode.findMany({
    select: { telegramFileId: true, seriesId: true, episodeNumber: true },
  });
  const seenFileIds = new Set(existingEpisodes.map((e) => e.telegramFileId).filter(Boolean));
  const seenEpKeys  = new Set(existingEpisodes.map((e) => `${e.seriesId}::${e.episodeNumber}`));

  const episodesToCreate = [];
  let   skipped          = 0;

  for (const msg of audioPosts) {
    const audio   = msg.audio;
    const fileId  = audio.file_id;
    const caption = msg.caption || '';

    if (seenFileIds.has(fileId)) { skipped++; continue; }

    // Caption format: "Series Title — EP1: Episode Title"
    // Filename format: SeriesTitle_EP01_EpisodeTitle.m4a
    const captionMatch  = caption.match(/^(.+?)\s*[—\-]+\s*EP(\d+)[:\s]+(.+)$/i);
    const fileNameMatch = audio.file_name?.match(/^(.+?)_EP(\d+)[_\s]+(.+?)\./i);
    const match         = captionMatch || fileNameMatch;

    if (!match) {
      console.warn(
        `⚠️  [Stories] Cannot parse series/episode from: "${caption || audio.file_name}"`
      );
      skipped++;
      continue;
    }

    const seriesTitle  = match[1].trim();
    const episodeNum   = parseInt(match[2]);
    const episodeTitle = match[3].trim();

    // Find or auto-create series
    let series = seriesMap.get(seriesTitle.toLowerCase());
    if (!series) {
      series = await prisma.series.create({ data: { title: seriesTitle } });
      seriesMap.set(seriesTitle.toLowerCase(), series);
      console.log(`📚 [Stories] Created new series: "${seriesTitle}"`);
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
    const BATCH = 100;
    for (let i = 0; i < episodesToCreate.length; i += BATCH) {
      await prisma.episode.createMany({
        data:           episodesToCreate.slice(i, i + BATCH),
        skipDuplicates: true,
      });
    }
    console.log(`🎙️  [Stories] Inserted ${episodesToCreate.length} episodes, skipped ${skipped}`);
  }

  if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });

  return { created: episodesToCreate.length, skipped, scanned: raw.length };
}

// ── runCoversSync ─────────────────────────────────────────────────────────────
async function runCoversSync() {
  const state        = await readState();
  const fromUpdateId = state.coversLastUpdateId || 0;

  console.log(`\n🖼️  [Covers Sync] Starting — last update_id: ${fromUpdateId}`);

  const { messages: raw, lastUpdateId } = await fetchAllUpdates(COVERS_CHANNEL_ID, fromUpdateId);
  console.log(`🖼️  [Covers] ${raw.length} channel posts received total`);

  const photoMessages = raw.filter((m) => m.photo);
  console.log(`🖼️  [Covers] ${photoMessages.length} photo messages to process`);

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
      const album =
        albumMap.get(name) ??
        [...albumMap.values()].find((a) => a.title.toLowerCase().includes(name));
      if (album) {
        albumUpdates.push({ id: album.id, fileId });
        console.log(`🖼️  [Covers] Matched album: "${album.title}"`);
      } else {
        console.warn(`⚠️  [Covers] No album matched for: "${name}"`);
      }
    }

    if (seriesMatch) {
      const name   = seriesMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
      const series =
        seriesMap.get(name) ??
        [...seriesMap.values()].find((s) => s.title.toLowerCase().includes(name));
      if (series) {
        seriesUpdates.push({ id: series.id, fileId });
        console.log(`🖼️  [Covers] Matched series: "${series.title}"`);
      } else {
        console.warn(`⚠️  [Covers] No series matched for: "${name}"`);
      }
    }
  }

  // Run DB updates in parallel
  await Promise.all([
    ...albumUpdates.map(({ id, fileId }) =>
      prisma.album.update({ where: { id }, data: { coverTelegramFileId: fileId } })
    ),
    ...seriesUpdates.map(({ id, fileId }) =>
      prisma.series.update({ where: { id }, data: { coverTelegramFileId: fileId } })
    ),
  ]);

  if (lastUpdateId > fromUpdateId) await saveState({ coversLastUpdateId: lastUpdateId });

  return {
    updated: albumUpdates.length + seriesUpdates.length,
    scanned: raw.length,
  };
}

// ── ROUTES ────────────────────────────────────────────────────────────────────
// All sync routes now respond SYNCHRONOUSLY with full results.
// The dashboard HTML and Flutter app both expect { created, skipped, albums }
// or { updated } in the response body — so we await the sync before replying.
//
// For very large channels (1000+ files) consider the async pattern with polling,
// but for typical usage (< 2000 files) a synchronous response is fine because
// Render's request timeout is 30 s and each sync run completes well within that.

// POST /api/sync/music
router.post('/music', async (req, res, next) => {
  if (syncStatus.music.running) {
    return res.status(409).json({
      error:   'Music sync already running',
      message: 'Poll GET /api/sync/status for the current result',
    });
  }

  syncStatus.music = {
    ...syncStatus.music,
    running:     true,
    lastError:   null,
    lastRun:     new Date().toISOString(),
    lastResult:  null,
  };

  try {
    const result               = await runMusicSync();
    syncStatus.music.lastResult = result;
    res.json({ success: true, ...result });
  } catch (err) {
    syncStatus.music.lastError = err.message;
    console.error('❌ [Music] sync failed:', err.message);
    next(err);
  } finally {
    syncStatus.music.running = false;
  }
});

// POST /api/sync/stories
router.post('/stories', async (req, res, next) => {
  if (syncStatus.stories.running) {
    return res.status(409).json({
      error:   'Stories sync already running',
      message: 'Poll GET /api/sync/status for the current result',
    });
  }

  syncStatus.stories = {
    ...syncStatus.stories,
    running:     true,
    lastError:   null,
    lastRun:     new Date().toISOString(),
    lastResult:  null,
  };

  try {
    const result                  = await runStoriesSync();
    syncStatus.stories.lastResult  = result;
    res.json({ success: true, ...result });
  } catch (err) {
    syncStatus.stories.lastError = err.message;
    console.error('❌ [Stories] sync failed:', err.message);
    next(err);
  } finally {
    syncStatus.stories.running = false;
  }
});

// POST /api/sync/covers
router.post('/covers', async (req, res, next) => {
  if (syncStatus.covers.running) {
    return res.status(409).json({
      error:   'Covers sync already running',
      message: 'Poll GET /api/sync/status for the current result',
    });
  }

  syncStatus.covers = {
    ...syncStatus.covers,
    running:     true,
    lastError:   null,
    lastRun:     new Date().toISOString(),
    lastResult:  null,
  };

  try {
    const result                 = await runCoversSync();
    syncStatus.covers.lastResult  = result;
    res.json({ success: true, ...result });
  } catch (err) {
    syncStatus.covers.lastError = err.message;
    console.error('❌ [Covers] sync failed:', err.message);
    next(err);
  } finally {
    syncStatus.covers.running = false;
  }
});

// GET /api/sync/status
router.get('/status', async (req, res, next) => {
  try {
    const state = await readState();
    res.json({
      success: true,
      data:    {
        music:   syncStatus.music,
        stories: syncStatus.stories,
        covers:  syncStatus.covers,
        state,
      },
    });
  } catch (err) {
    next(err);
  }
});

// POST /api/sync/reset — re-scans everything from the beginning (offset = 0)
router.post('/reset', async (req, res, next) => {
  try {
    await saveState({
      musicLastUpdateId:   0,
      storiesLastUpdateId: 0,
      coversLastUpdateId:  0,
    });
    syncStatus.music.lastResult   = null;
    syncStatus.stories.lastResult = null;
    syncStatus.covers.lastResult  = null;
    res.json({
      success: true,
      message: 'Sync state reset. Next run will fetch ALL updates from the beginning.',
    });
  } catch (err) {
    next(err);
  }
});

module.exports = router;