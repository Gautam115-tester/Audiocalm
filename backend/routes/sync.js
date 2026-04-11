// routes/sync.js
// FIX: Call invalidateSeriesCache() after a successful stories sync so the
// all-with-episodes NodeCache is flushed immediately.
//
// EPISODE 64 FIX + SPACED-FILENAME FIX — runStoriesSync() filename parser
// ========================================================================
//
// ROOT CAUSE (ep 64):
// Episode 64's Telegram filename is:  KarnaPishachini_Ep64.m4a
//   → no title segment after EP number → old Pattern 3 required one → skipped.
//   FIX: Pattern 3b matches filenames where episode number is last before ext.
//
// NEW FORMAT SUPPORTED (Aayra-style):
// Telegram filenames like:  "Aayra shaadi ya khauf Ep 16_part01.aac"
//                            "Aayra shaadi ya khauf Ep 16_part02.aac"
//                            "Aayra shaadi ya khauf Ep 18.aac"
// Features:
//   • Series name contains SPACES (not just underscores)
//   • "Ep" has a SPACE before the episode number: "Ep 16"
//   • Multi-part suffix: "_part01", "_part02"
//   • Extension: .aac (already handled by normalizeAudio)
//
// ALL PATTERNS now use a greedy series-name group that accepts spaces,
// and the Ep/EP separator allows an optional space: [Ee][Pp]\s*(\d+)
//
// ALSO FIXED: normalizeAudio() now explicitly accepts .m4a / .aac / .ogg
//   MIME types in addition to the existing audio/* wildcard, ensuring the
//   document branch handles them even if Telegram sends a non-standard type.
//
// ALL OTHER SYNC LOGIC IS UNCHANGED.

const express = require('express');
const router  = require('express').Router();
const axios   = require('axios');
const prisma  = require('../services/db');

const { invalidateSeriesCache } = require('./series');
const { invalidateAlbumCache  } = require('./albums');

const BOT_TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;

const MUSIC_CHANNEL_ID   = process.env.TELEGRAM_MUSIC_CHANNEL_ID;
const STORIES_CHANNEL_ID = process.env.TELEGRAM_STORIES_CHANNEL_ID;
const COVERS_CHANNEL_ID  = process.env.TELEGRAM_COVERS_CHANNEL_ID;

for (const key of [
  'TELEGRAM_BOT_TOKEN',
  'TELEGRAM_MUSIC_CHANNEL_ID',
  'TELEGRAM_STORIES_CHANNEL_ID',
  'TELEGRAM_COVERS_CHANNEL_ID',
]) {
  if (!process.env[key]) console.error(`❌ Missing env var: ${key}`);
}

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

const syncStatus = {
  music:   { running: false, lastResult: null, lastError: null, lastRun: null },
  stories: { running: false, lastResult: null, lastError: null, lastRun: null },
  covers:  { running: false, lastResult: null, lastError: null, lastRun: null },
};

// ── FIX: normalizeAudio now explicitly handles .m4a / .aac / .ogg ────────────
// Telegram sometimes sends these as documents with mime_type 'audio/mp4',
// 'audio/aac', 'audio/ogg', or even 'video/mp4' for .m4a files.
// The existing `audio/*` wildcard covers most cases, but we add an explicit
// extension check as a belt-and-suspenders fallback.

const AUDIO_EXTENSIONS = /\.(mp3|m4a|aac|ogg|opus|flac|wav|m4b)$/i;

function normalizeAudio(msg) {
  if (msg.audio) return msg.audio;

  const doc = msg.document;
  if (!doc) return null;

  const mimeOk = doc.mime_type && (
    doc.mime_type.startsWith('audio/') ||
    doc.mime_type === 'video/mp4'        // Telegram sometimes sends .m4a as video/mp4
  );
  const extOk = doc.file_name && AUDIO_EXTENSIONS.test(doc.file_name);

  if (mimeOk || extOk) {
    return {
      file_id:        doc.file_id,
      file_name:      doc.file_name  || null,
      file_size:      doc.file_size  || null,
      duration:       doc.duration   || 0,
      performer:      doc.performer  || null,
      title:          doc.title      || null,
      _from_document: true,
    };
  }

  return null;
}

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

async function runMusicSync() {
  const state        = await readState();
  const fromUpdateId = state.musicLastUpdateId || 0;

  console.log(`\n🎵 [Music Sync] Starting — last update_id: ${fromUpdateId}`);

  const { messages: raw, lastUpdateId } = await fetchAllUpdates(MUSIC_CHANNEL_ID, fromUpdateId);
  console.log(`🎵 [Music] ${raw.length} channel posts received total`);

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
    if (!album) { skipped++; continue; }

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
//
// Parsing priority (checked in order):
//
//   Pattern 1 — Multi-part filename (underscore OR space separator, optional space after Ep):
//     SeriesName_Ep63_Part1.mp3
//     Aayra shaadi ya khauf Ep 16_part01.aac
//     Regex: /^(.+?)\s*[Ee][Pp]\s*(\d+)[\s_\-]+[Pp](?:art)?[\s_\-]?(\d+)\./i
//
//   Pattern 2 — Caption with title:
//     "Series Name — EP64: Episode Title"
//     Regex: /^(.+?)\s*[—\-]+\s*EP(\d+)[:\s]+(.+)$/i
//
//   Pattern 3 — Filename with title (optional space after Ep):
//     SeriesName_EP64_EpisodeTitle.mp3
//     Regex: /^(.+?)\s*[Ee][Pp]\s*(\d+)[\s_]+(.+?)\./i
//
//   Pattern 3b — Filename WITHOUT title (optional space after Ep):
//     KarnaPishachini_Ep64.m4a
//     Aayra shaadi ya khauf Ep 18.aac
//     Regex: /^(.+?)\s*[Ee][Pp]\s*(\d+)\.[a-z0-9]{2,5}$/i
//     Title falls back to "Episode N"

async function runStoriesSync() {
  const state        = await readState();
  const fromUpdateId = state.storiesLastUpdateId || 0;

  console.log(`\n🎙️  [Stories Sync] Starting — last update_id: ${fromUpdateId}`);

  const { messages: raw, lastUpdateId } = await fetchAllUpdates(STORIES_CHANNEL_ID, fromUpdateId);
  console.log(`🎙️  [Stories] ${raw.length} channel posts received total`);

  const audioPosts = raw
    .map((m) => ({ ...m, _audio: normalizeAudio(m) }))
    .filter((m) => m._audio != null);

  const docCount = audioPosts.filter((m) => m._audio._from_document).length;
  console.log(`🎙️  [Stories] ${audioPosts.length} audio messages to process (${docCount} as document type)`);

  if (audioPosts.length === 0) {
    if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });
    return { created: 0, updated: 0, skipped: 0, scanned: raw.length };
  }

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

  const parsed = [];
  let globalSkipped = 0;

  for (const msg of audioPosts) {
    const audio    = msg._audio;
    const fileId   = audio.file_id;
    const caption  = msg.caption || '';
    const fileName = audio.file_name || '';

    if (seenFileIds.has(fileId)) { globalSkipped++; continue; }

    // ── Pattern 1: Multi-part filename ──────────────────────────────────────
    // Old: KarnaPishachini_Ep63_Part1.mp3  (underscore/dash separator before Ep)
    // New: Aayra shaadi ya khauf Ep 16_part01.aac  (space before/after Ep)
    const partMatch =
      fileName.match(/^(.+?)[\s_\-]+[Ee][Pp](\d+)[\s_\-]+[Pp](?:art)?[\s_\-]?(\d+)\./i) ||
      fileName.match(/^(.+?)\s*[Ee][Pp]\s*(\d+)[\s_\-]+[Pp](?:art)?[\s_\-]?(\d+)\./i);

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
      console.log(`  ✅ [Pattern 1 multi-part] "${fileName}" → ${seriesTitle} EP${episodeNum} Part${partNum}`);
      continue;
    }

    // ── Pattern 2: Caption with title ────────────────────────────────────────
    // e.g. "KarnaPishachini — EP64: The Dark Forest"
    const captionMatch = caption.match(/^(.+?)\s*[—\-]+\s*EP(\d+)[:\s]+(.+)$/i);

    if (captionMatch) {
      parsed.push({
        seriesTitle:  captionMatch[1].trim(),
        episodeNum:   parseInt(captionMatch[2]),
        partNum:      null,
        episodeTitle: captionMatch[3].trim(),
        fileId,
        duration: audio.duration ?? 0,
      });
      console.log(`  ✅ [Pattern 2 caption] "${caption}" → EP${captionMatch[2]}`);
      continue;
    }

    // ── Pattern 3: Filename with title ───────────────────────────────────────
    // Old: KarnaPishachini_EP64_TheDarkForest.mp3  (underscore before EP)
    // New: Series Name EP 64 Some Title.mp3  (space, optional space after Ep)
    const fileNameMatch =
      fileName.match(/^(.+?)_EP(\d+)[_\s]+(.+?)\./i) ||
      fileName.match(/^(.+?)\s*[Ee][Pp]\s*(\d+)[\s_]+(.+?)\./i);

    if (fileNameMatch) {
      parsed.push({
        seriesTitle:  fileNameMatch[1].replace(/[_\-]+/g, ' ').trim(),
        episodeNum:   parseInt(fileNameMatch[2]),
        partNum:      null,
        episodeTitle: fileNameMatch[3].replace(/[_\-]+/g, ' ').trim(),
        fileId,
        duration: audio.duration ?? 0,
      });
      console.log(`  ✅ [Pattern 3 filename+title] "${fileName}" → EP${fileNameMatch[2]}`);
      continue;
    }

    // ── Pattern 3b: Filename WITHOUT title ───────────────────────────────────
    // Old: KarnaPishachini_Ep64.m4a  (underscore/dash before Ep, no space after)
    // New: Aayra shaadi ya khauf Ep 18.aac  (space before/after Ep, spaced series)
    const fileNameNoTitleMatch =
      fileName.match(/^(.+?)[\s_\-]*[Ee][Pp](\d+)\.[a-z0-9]{2,4}$/i) ||
      fileName.match(/^(.+?)\s*[Ee][Pp]\s*(\d+)\.[a-z0-9]{2,5}$/i);

    if (fileNameNoTitleMatch) {
      const seriesTitle = fileNameNoTitleMatch[1].replace(/[_\-]+/g, ' ').trim();
      const episodeNum  = parseInt(fileNameNoTitleMatch[2]);
      parsed.push({
        seriesTitle,
        episodeNum,
        partNum:      null,
        episodeTitle: `Episode ${episodeNum}`, // no title in filename — use generic
        fileId,
        duration: audio.duration ?? 0,
      });
      console.log(`  ✅ [Pattern 3b filename-no-title] "${fileName}" → ${seriesTitle} EP${episodeNum}`);
      continue;
    }

    // ── No pattern matched ────────────────────────────────────────────────────
    console.warn(`⚠️  [Stories] Cannot parse (skipped): caption="${caption}" fileName="${fileName}"`);
    globalSkipped++;
  }

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

      trulyNewIds.forEach((id) => seenFileIds.add(id));
      continue;
    }

    const telegramFileId = newPartCount === 1 ? newFileIds[0] : JSON.stringify(newFileIds);
    const totalDuration  = newPartDuration || null;

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

  if (episodesToCreate.length > 0) {
    const BATCH = 100;
    for (let i = 0; i < episodesToCreate.length; i += BATCH) {
      await prisma.episode.createMany({
        data:           episodesToCreate.slice(i, i + BATCH),
        skipDuplicates: true,
      });
    }
    console.log(`🎙️  [Stories] Created ${episodesToCreate.length} episode(s)`);
  }

  if (episodesToUpdate.length > 0) {
    await Promise.all(
      episodesToUpdate.map(({ id, telegramFileId, duration, partCount }) =>
        prisma.episode.update({
          where: { id },
          data:  { telegramFileId, duration, partCount },
        })
      )
    );
    console.log(`🎙️  [Stories] Updated ${episodesToUpdate.length} episode(s)`);
  }

  if (lastUpdateId > fromUpdateId) await saveState({ storiesLastUpdateId: lastUpdateId });

  return {
    created: episodesToCreate.length,
    updated: episodesToUpdate.length,
    skipped: skipped + globalSkipped,
    scanned: raw.length,
  };
}

async function runCoversSync() {
  const state        = await readState();
  const fromUpdateId = state.coversLastUpdateId || 0;

  console.log(`\n🖼️  [Covers Sync] Starting — last update_id: ${fromUpdateId}`);

  const { messages: raw, lastUpdateId } = await fetchAllUpdates(COVERS_CHANNEL_ID, fromUpdateId);
  const photoMessages = raw.filter((m) => m.photo);

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
      const album = albumMap.get(name) ??
        [...albumMap.values()].find((a) => a.title.toLowerCase().includes(name));
      if (album) albumUpdates.push({ id: album.id, fileId });
    }

    if (seriesMatch) {
      const name   = seriesMatch[1].replace(/\([^)]*\)/g, '').trim().toLowerCase();
      const series = seriesMap.get(name) ??
        [...seriesMap.values()].find((s) => s.title.toLowerCase().includes(name));
      if (series) seriesUpdates.push({ id: series.id, fileId });
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

router.post('/music', async (req, res, next) => {
  if (syncStatus.music.running) {
    return res.status(409).json({ error: 'Music sync already running' });
  }
  syncStatus.music = { ...syncStatus.music, running: true, lastError: null, lastRun: new Date().toISOString(), lastResult: null };
  try {
    const result = await runMusicSync();
    syncStatus.music.lastResult = result;
    try { invalidateAlbumCache?.(); } catch (_) {}
    res.json({ success: true, ...result });
  } catch (err) {
    syncStatus.music.lastError = err.message;
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
    try { invalidateSeriesCache(); } catch (_) {}
    res.json({ success: true, ...result });
  } catch (err) {
    syncStatus.stories.lastError = err.message;
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
    res.json({ success: true, message: 'Sync state reset.' });
  } catch (err) { next(err); }
});

module.exports = router;