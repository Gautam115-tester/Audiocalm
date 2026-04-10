// routes/sync.js
// Syncs music, audio stories, and cover images from Telegram channels into the DB.
//
// DOCUMENT FIX:
//   Telegram sometimes stores uploaded audio as `document` instead of `audio`
//   (happens when the file is sent via sendDocument or auto-classified by Telegram).
//   Both runMusicSync and runStoriesSync now normalise document posts into the
//   same shape as audio posts so the rest of the logic works unchanged.
//   normalizeAudio(msg) returns a unified audio object from either msg.audio or
//   msg.document (as long as the document mime_type starts with "audio/").

const express = require('express');
const router  = require('express').Router();
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

// ── State helpers ─────────────────────────────────────────────────────────────
let memState = {
  musicLastUpdateId:   0,
  storiesLastUpdateId: 0,
  coversLastUpdateId:  0,
};

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

// ── normalizeAudio ────────────────────────────────────────────────────────────
// FIX: Telegram sometimes delivers audio files as `document` instead of `audio`.
// This happens when:
//   - The file is uploaded via sendDocument instead of sendAudio
//   - Telegram auto-classifies the file based on its mime type
//
// This function returns a unified audio-like object from either field:
//   { file_id, file_name, duration, performer, title, file_size }
//
// Returns null if the message has no audio or audio-like document.
function normalizeAudio(msg) {
  // Standard audio message
  if (msg.audio) return msg.audio;

  // Document with audio mime type (the case we're fixing)
  const doc = msg.document;
  if (doc && doc.mime_type && doc.mime_type.startsWith('audio/')) {
    return {
      file_id:   doc.file_id,
      file_name: doc.file_name  || null,
      file_size: doc.file_size  || null,
      duration:  doc.duration   || 0,    // documents don't have duration — sync uses filename
      performer: doc.performer  || null,
      title:     doc.title      || null,
      _from_document: true,              // flag for debugging
    };
  }

  return null;
}

// ── fetchAllUpdates ───────────────────────────────────────────────────────────
async function fetchAllUpdates(channelId, fromUpdateId = 0) {
  const messages     = [];
  let   offset       = fromUpdateId > 0 ? fromUpdateId + 1 : 0;
  let   totalFetched = 0;
  let   pageNum      = 0;

  console.log(`  📡 Starting paginated fetch from offset ${offset} for channel ${channelId}`);

  while (true) {
    pageNum++;
    let updates = [];

    try {
      const res = await axios.get(`${TELEGRAM_API}/getUpdates`, {
        params: {
          offset,
          limit:           100,
          timeout:         0,
          allowed_updates: ['channel_post'],
        },
        timeout: 30_000,
      });
      updates = res.data.result || [];
    } catch (err) {
      const status = err.response?.status;
      const desc   = err.response?.data?.description || err.message;
      console.error(`  ❌ getUpdates page ${pageNum} error (HTTP ${status}): ${desc}`);
      break;
    }

    totalFetched += updates.length;
    console.log(`  📦 Page ${pageNum}: ${updates.length} updates (total so far: ${totalFetched})`);

    if (updates.length === 0) break;

    for (const update of updates) {
      const post = update.channel_post;
      if (post && String(post.chat.id) === String(channelId)) {
        messages.push({ update_id: update.update_id, ...post });
      }
      offset = update.update_id + 1;
    }

    if (updates.length < 100) break;
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

  // FIX: use normalizeAudio — picks up both audio and document posts
  const audioPosts = raw
    .map((m) => ({ ...m, _audio: normalizeAudio(m) }))
    .filter((m) => m._audio != null);

  const docCount = audioPosts.filter((m) => m._audio._from_document).length;
  console.log(`🎵 [Music] ${audioPosts.length} audio messages to process (${docCount} as document type)`);

  if (audioPosts.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ musicLastUpdateId: lastUpdateId });
    return { created: 0, skipped: 0, scanned: raw.length, albums: 0 };
  }

  const existingAlbums = await prisma.album.findMany({ select: { id: true, title: true } });
  const albumMap       = new Map(existingAlbums.map((a) => [a.title.toLowerCase(), a]));

  const existingSongs  = await prisma.song.findMany({
    select: { telegramFileId: true, title: true, albumId: true },
  });
  const seenFileIds    = new Set(existingSongs.map((s) => s.telegramFileId).filter(Boolean));
  const seenTitleAlbum = new Set(existingSongs.map((s) => `${s.title.toLowerCase()}::${s.albumId}`));

  const albumsToCreate = new Map();
  for (const msg of audioPosts) {
    const a    = msg._audio;
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

  const trackAgg    = await prisma.song.groupBy({ by: ['albumId'], _max: { trackNumber: true } });
  const maxTrackMap = new Map(trackAgg.map((r) => [r.albumId, r._max.trackNumber || 0]));
  const sessionMax  = new Map();

  const songsToCreate = [];
  let   skipped       = 0;

  for (const msg of audioPosts) {
    const audio     = msg._audio;
    const title     = audio.title || audio.file_name || 'Unknown';
    const performer = audio.performer || null;
    const fileId    = audio.file_id;
    const duration  = audio.duration ?? null;

    if (seenFileIds.has(fileId)) { skipped++; continue; }

    const albumName = cleanAlbumName(audio.file_name, performer);
    const album     = albumMap.get(albumName.toLowerCase());
    if (!album) {
      console.warn(`⚠️  [Music] No album matched for "${albumName}" — skipping`);
      skipped++;
      continue;
    }

    const titleKey = `${title.toLowerCase()}::${album.id}`;
    if (seenTitleAlbum.has(titleKey)) { skipped++; continue; }

    const trMatch  = audio.file_name?.match(/TR(\d+)/i);
    let   trackNum = trMatch ? parseInt(trMatch[1]) : null;

    if (trackNum !== null && sessionMax.has(`${album.id}::${trackNum}`)) {
      trackNum = null;
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
    created: songsToCreate.length,
    skipped,
    scanned: raw.length,
    albums:  albumMap.size,
  };
}

// ── runStoriesSync ────────────────────────────────────────────────────────────
async function runStoriesSync() {
  const state        = await readState();
  const fromUpdateId = state.storiesLastUpdateId || 0;

  console.log(`\n🎙️  [Stories Sync] Starting — last update_id: ${fromUpdateId}`);

  const { messages: raw, lastUpdateId } = await fetchAllUpdates(STORIES_CHANNEL_ID, fromUpdateId);
  console.log(`🎙️  [Stories] ${raw.length} channel posts received total`);

  // FIX: use normalizeAudio — picks up both audio and document posts
  const audioPosts = raw
    .map((m) => ({ ...m, _audio: normalizeAudio(m) }))
    .filter((m) => m._audio != null);

  const docCount = audioPosts.filter((m) => m._audio._from_document).length;
  console.log(`🎙️  [Stories] ${audioPosts.length} audio messages to process (${docCount} as document type)`);

  if (audioPosts.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });
    return { created: 0, updated: 0, skipped: 0, scanned: raw.length };
  }

  // ── Load existing data ─────────────────────────────────────────────────────
  const allSeries  = await prisma.series.findMany({ select: { id: true, title: true } });
  const seriesMap  = new Map(allSeries.map((s) => [s.title.toLowerCase(), s]));

  const existingEpisodes = await prisma.episode.findMany({
    select: { id: true, telegramFileId: true, seriesId: true, episodeNumber: true, duration: true, partCount: true },
  });

  const existingEpMap = new Map(
    existingEpisodes.map((e) => [`${e.seriesId}::${e.episodeNumber}`, e])
  );

  const seenFileIds = new Set();
  for (const ep of existingEpisodes) {
    if (!ep.telegramFileId) continue;
    if (ep.telegramFileId.startsWith('[')) {
      try { JSON.parse(ep.telegramFileId).forEach((id) => seenFileIds.add(id)); }
      catch { seenFileIds.add(ep.telegramFileId); }
    } else {
      seenFileIds.add(ep.telegramFileId);
    }
  }

  // ── Parse each audio post ──────────────────────────────────────────────────
  const parsed = [];
  let globalSkipped = 0;

  for (const msg of audioPosts) {
    const audio    = msg._audio;   // FIX: use normalised audio object
    const fileId   = audio.file_id;
    const caption  = msg.caption || '';
    const fileName = audio.file_name || '';

    if (seenFileIds.has(fileId)) { globalSkipped++; continue; }

    // Pattern: SeriesName_Ep01_part01.mp3
    const partMatch = fileName.match(
      /^(.+?)[\s_\-]+[Ee][Pp](\d+)[\s_\-]+[Pp](?:art)?[\s_\-]?(\d+)\./i
    );

    if (partMatch) {
      const seriesTitle = partMatch[1].replace(/[_\-]+/g, ' ').trim();
      const episodeNum  = parseInt(partMatch[2]);
      const partNum     = parseInt(partMatch[3]);
      parsed.push({
        seriesTitle,
        episodeNum,
        partNum,
        episodeTitle: `Episode ${episodeNum}`,
        fileId,
        duration: audio.duration ?? 0,
      });
      continue;
    }

    // Caption: "Series Title — EP1: Episode Title"
    const captionMatch  = caption.match(/^(.+?)\s*[—\-]+\s*EP(\d+)[:\s]+(.+)$/i);
    // Filename (no parts): SeriesTitle_EP01_EpisodeTitle.mp3
    const fileNameMatch = fileName.match(/^(.+?)_EP(\d+)[_\s]+(.+?)\./i);
    const match         = captionMatch || fileNameMatch;

    if (!match) {
      console.warn(`⚠️  [Stories] Cannot parse: "${caption || fileName}"`);
      globalSkipped++;
      continue;
    }

    parsed.push({
      seriesTitle:  match[1].trim(),
      episodeNum:   parseInt(match[2]),
      partNum:      null,
      episodeTitle: match[3].trim(),
      fileId,
      duration: audio.duration ?? 0,
    });
  }

  // ── Group by "seriesTitle::episodeNum" ─────────────────────────────────────
  const groups = new Map();

  for (const item of parsed) {
    const key = `${item.seriesTitle.toLowerCase()}::${item.episodeNum}`;
    if (!groups.has(key)) {
      groups.set(key, {
        seriesTitle:  item.seriesTitle,
        episodeNum:   item.episodeNum,
        episodeTitle: item.episodeTitle,
        parts: [],
      });
    }
    groups.get(key).parts.push({
      partNum:  item.partNum ?? 1,
      fileId:   item.fileId,
      duration: item.duration,
    });
  }

  // ── Process each group ─────────────────────────────────────────────────────
  const episodesToCreate = [];
  const episodesToUpdate = [];
  let skipped = 0;

  for (const [, group] of groups) {
    group.parts.sort((a, b) => a.partNum - b.partNum);

    let series = seriesMap.get(group.seriesTitle.toLowerCase());
    if (!series) {
      series = await prisma.series.create({ data: { title: group.seriesTitle } });
      seriesMap.set(group.seriesTitle.toLowerCase(), series);
      console.log(`📚 [Stories] Created new series: "${group.seriesTitle}"`);
    }

    const dbKey    = `${series.id}::${group.episodeNum}`;
    const existing = existingEpMap.get(dbKey);

    const newPartDuration = group.parts.reduce((s, p) => s + (p.duration || 0), 0);
    const newPartCount    = group.parts.length;
    const newFileIds      = group.parts.map((p) => p.fileId);

    if (existing) {
      let storedFileIds = [];
      if (existing.telegramFileId) {
        if (existing.telegramFileId.startsWith('[')) {
          try { storedFileIds = JSON.parse(existing.telegramFileId); } catch {}
        } else {
          storedFileIds = [existing.telegramFileId];
        }
      }

      const trulyNewIds = newFileIds.filter((id) => !storedFileIds.includes(id));

      if (trulyNewIds.length === 0) {
        skipped++;
        continue;
      }

      const mergedIds            = [...storedFileIds, ...trulyNewIds];
      const mergedTelegramFileId = mergedIds.length === 1 ? mergedIds[0] : JSON.stringify(mergedIds);
      const additionalDuration   = group.parts
        .filter((p) => trulyNewIds.includes(p.fileId))
        .reduce((s, p) => s + (p.duration || 0), 0);
      const mergedDuration  = (existing.duration || 0) + additionalDuration;
      const mergedPartCount = mergedIds.length;

      episodesToUpdate.push({
        id:             existing.id,
        telegramFileId: mergedTelegramFileId,
        duration:       mergedDuration || null,
        partCount:      mergedPartCount,
      });

      console.log(
        `🔄 [Stories] Merging ${trulyNewIds.length} new part(s) into ` +
        `"${group.seriesTitle}" EP${group.episodeNum} ` +
        `(now ${mergedPartCount} parts, ${mergedDuration}s total)`
      );

      trulyNewIds.forEach((id) => seenFileIds.add(id));
      continue;
    }

    // Brand new episode
    const telegramFileId = newPartCount === 1 ? newFileIds[0] : JSON.stringify(newFileIds);
    const totalDuration  = newPartDuration || null;

    console.log(
      `✨ [Stories] New episode: "${group.seriesTitle}" EP${group.episodeNum} ` +
      `— ${newPartCount} part(s), ${totalDuration}s total`
    );

    newFileIds.forEach((id) => seenFileIds.add(id));
    existingEpMap.set(dbKey, { id: 'pending', seriesId: series.id, episodeNumber: group.episodeNum });

    episodesToCreate.push({
      seriesId:       series.id,
      episodeNumber:  group.episodeNum,
      title:          group.episodeTitle,
      telegramFileId,
      duration:       totalDuration,
      partCount:      newPartCount,
    });
  }

  // ── Batch CREATE ───────────────────────────────────────────────────────────
  if (episodesToCreate.length > 0) {
    const BATCH = 100;
    for (let i = 0; i < episodesToCreate.length; i += BATCH) {
      await prisma.episode.createMany({
        data:           episodesToCreate.slice(i, i + BATCH),
        skipDuplicates: true,
      });
    }
    console.log(
      `🎙️  [Stories] Created ${episodesToCreate.length} episode(s) ` +
      `(${episodesToCreate.filter(e => e.partCount > 1).length} multi-part)`
    );
  }

  // ── Batch UPDATE ───────────────────────────────────────────────────────────
  if (episodesToUpdate.length > 0) {
    await Promise.all(
      episodesToUpdate.map(({ id, telegramFileId, duration, partCount }) =>
        prisma.episode.update({
          where: { id },
          data:  { telegramFileId, duration, partCount },
        })
      )
    );
    console.log(`🔄 [Stories] Updated ${episodesToUpdate.length} episode(s) with new parts`);
  }

  if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });

  return {
    created: episodesToCreate.length,
    updated: episodesToUpdate.length,
    skipped: skipped + globalSkipped,
    scanned: raw.length,
  };
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
    const fileId  = msg.photo[msg.photo.length - 1].file_id;

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

router.post('/music', async (req, res, next) => {
  if (syncStatus.music.running) {
    return res.status(409).json({ error: 'Music sync already running' });
  }
  syncStatus.music = { ...syncStatus.music, running: true, lastError: null, lastRun: new Date().toISOString(), lastResult: null };
  try {
    const result = await runMusicSync();
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

router.post('/stories', async (req, res, next) => {
  if (syncStatus.stories.running) {
    return res.status(409).json({ error: 'Stories sync already running' });
  }
  syncStatus.stories = { ...syncStatus.stories, running: true, lastError: null, lastRun: new Date().toISOString(), lastResult: null };
  try {
    const result = await runStoriesSync();
    syncStatus.stories.lastResult = result;
    res.json({ success: true, ...result });
  } catch (err) {
    syncStatus.stories.lastError = err.message;
    console.error('❌ [Stories] sync failed:', err.message);
    next(err);
  } finally {
    syncStatus.stories.running = false;
  }
});

router.post('/covers', async (req, res, next) => {
  if (syncStatus.covers.running) {
    return res.status(409).json({ error: 'Covers sync already running' });
  }
  syncStatus.covers = { ...syncStatus.covers, running: true, lastError: null, lastRun: new Date().toISOString(), lastResult: null };
  try {
    const result = await runCoversSync();
    syncStatus.covers.lastResult = result;
    res.json({ success: true, ...result });
  } catch (err) {
    syncStatus.covers.lastError = err.message;
    console.error('❌ [Covers] sync failed:', err.message);
    next(err);
  } finally {
    syncStatus.covers.running = false;
  }
});

router.get('/status', async (req, res, next) => {
  try {
    const state = await readState();
    res.json({ success: true, data: { music: syncStatus.music, stories: syncStatus.stories, covers: syncStatus.covers, state } });
  } catch (err) { next(err); }
});

router.post('/reset', async (req, res, next) => {
  try {
    await saveState({ musicLastUpdateId: 0, storiesLastUpdateId: 0, coversLastUpdateId: 0 });
    syncStatus.music.lastResult   = null;
    syncStatus.stories.lastResult = null;
    syncStatus.covers.lastResult  = null;
    res.json({ success: true, message: 'Sync state reset. Next run will fetch ALL updates from the beginning.' });
  } catch (err) { next(err); }
});

module.exports = router;