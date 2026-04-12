// routes/songs.js
//
// STREAMING UPGRADE — DIRECT REDIRECT + AGGRESSIVE PRE-WARMING
// =============================================================
//
// STREAM ARCHITECTURE CHANGE:
//   BEFORE: Render proxied every audio byte through the Node.js process.
//   NOW:    Render resolves the Telegram signed URL and sends a 302 redirect.
//           Audio streams directly from Telegram's CDN to the Flutter client.
//           Zero audio bytes flow through Render → no bandwidth, no timeout.
//
// PRE-WARMING STRATEGY:
//   When a song part is requested, we immediately fire background URL
//   resolution for upcoming content so they are cache-hot when needed:
//
//   On song X, part N request:
//     → Warm all remaining parts of song X        (same song, later parts)
//     → Warm ALL parts of song X+1 (same album)  (next song in album)
//     → Warm ALL parts of song X+2 (same album)  (song after that)
//
//   This means when just_audio transitions to the next track, the URL
//   is already cached → redirect resolves in <5ms → gapless playback.
//
// URL EXPIRY HANDLING:
//   Telegram signed URLs expire in ~1h. Our cache TTL is 45 min.
//   If just_audio receives a 401/403 from Telegram CDN it retries the
//   /stream endpoint. On retry header X-Force-Refresh: 1 is sent and
//   we force-evict the cache and re-resolve before redirecting.
//   The client never sees a playback gap.

const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ── Helper: resolve file ID for a given part ─────────────────────────────────
function resolveFileId(song, partNum = 1) {
  const raw = song.telegramFileId;
  if (!raw) return null;

  if (raw.startsWith('[')) {
    try {
      const parts = JSON.parse(raw);
      const idx   = Math.min(Math.max(partNum - 1, 0), parts.length - 1);
      return parts[idx] || null;
    } catch {
      return raw;
    }
  }

  return raw;
}

// ── Helper: parse all file IDs for a song ────────────────────────────────────
function parseFileIds(telegramFileId) {
  if (!telegramFileId) return [];
  if (telegramFileId.startsWith('[')) {
    try {
      return JSON.parse(telegramFileId).filter(Boolean);
    } catch {
      return telegramFileId ? [telegramFileId] : [];
    }
  }
  return [telegramFileId];
}

// ── Pre-warm next parts + next songs in background ───────────────────────────
// Called after we resolve the current request — non-blocking.
async function preWarmAhead(currentSong, requestedPartNum) {
  try {
    const allIds     = parseFileIds(currentSong.telegramFileId);
    const totalParts = allIds.length;

    // 1. Warm remaining parts of the current song (after the requested part)
    const futurePartIds = [];
    for (let p = requestedPartNum; p < totalParts; p++) {
      if (allIds[p]) futurePartIds.push(allIds[p]);
    }
    if (futurePartIds.length > 0) {
      telegram.preWarmBatch(futurePartIds, { concurrency: 2 }).catch(() => {});
    }

    // 2. Warm next 2 songs in the same album (ordered by trackNumber)
    const nextSongs = await prisma.song.findMany({
      where: {
        albumId:     currentSong.albumId,
        isActive:    true,
        trackNumber: { gt: currentSong.trackNumber },
      },
      orderBy: { trackNumber: 'asc' },
      take:    2,  // next 2 songs
      select:  { id: true, telegramFileId: true, trackNumber: true },
    });

    for (const song of nextSongs) {
      const ids = parseFileIds(song.telegramFileId);
      if (ids.length > 0) {
        // Warm first 2 parts of each upcoming song (enough to start instantly)
        telegram.preWarmBatch(ids.slice(0, 2), { concurrency: 2 }).catch(() => {});
      }
    }
  } catch (err) {
    // Pre-warming is best-effort — never let it affect the response
    console.warn('[songs] preWarmAhead error (non-fatal):', err.message);
  }
}

// ── GET /api/songs/:id/stream ─────────────────────────────────────────────────
// Returns a 302 redirect to the Telegram CDN URL.
// Audio streams directly from Telegram — zero Render bandwidth used.
// Query param: ?part=N  (1-based, default 1)
//
// URL REFRESH LOGIC:
//   If the request includes header X-Force-Refresh: 1 (sent by Flutter on retry
//   after a 401 from Telegram CDN), we force-evict the cache and re-resolve.
router.get('/:id/stream', async (req, res, next) => {
  try {
    const song = await prisma.song.findUnique({ where: { id: req.params.id } });
    if (!song)               return res.status(404).json({ error: 'Song not found' });
    if (!song.telegramFileId) return res.status(503).json({ error: 'Song audio not available yet. Run sync.' });

    const partNum = parseInt(req.query.part || '1', 10);
    if (isNaN(partNum) || partNum < 1 || partNum > song.partCount) {
      return res.status(400).json({ error: `Invalid part. Song has ${song.partCount} part(s).` });
    }

    const fileId = resolveFileId(song, partNum);
    if (!fileId) return res.status(503).json({ error: 'File ID missing — re-sync required.' });

    // Force-refresh the cached URL if the client signals a prior 401 from CDN
    const forceRefresh = req.headers['x-force-refresh'] === '1' ||
                         req.query.refresh === '1';

    let url;
    if (forceRefresh) {
      url = await telegram.refreshUrl(fileId);
    } else {
      url = await telegram.getDirectUrl(fileId);
    }

    // ── DIRECT REDIRECT ──────────────────────────────────────────────────────
    // Client (Flutter/just_audio) will follow the redirect and stream
    // audio directly from Telegram's CDN. Zero bytes through Render.
    telegram.buildRedirectResponse(url, res);

    // ── PRE-WARM NEXT CONTENT (non-blocking, post-response) ─────────────────
    // Kick off background URL resolution for upcoming parts/songs.
    // setImmediate ensures this runs after the response is sent.
    setImmediate(() => preWarmAhead(song, partNum));

  } catch (err) {
    if (!res.headersSent) next(err);
  }
});

// ── HEAD /api/songs/:id/stream ────────────────────────────────────────────────
// Android audio player hits HEAD first to check size/type before buffering.
// Now just returns headers — no proxy needed.
router.head('/:id/stream', async (req, res) => {
  try {
    const song = await prisma.song.findUnique({
      where:  { id: req.params.id },
      select: { id: true, telegramFileId: true, duration: true, partCount: true },
    });

    if (!song || !song.telegramFileId) return res.status(404).end();

    res.setHeader('Accept-Ranges', 'bytes');
    res.setHeader('Content-Type',  'audio/mpeg');
    if (song.duration) res.setHeader('X-Duration', song.duration.toString());
    if (song.partCount > 1) {
      res.setHeader('X-Multi-Part',  'true');
      res.setHeader('X-Part-Count',  song.partCount.toString());
    }
    res.status(200).end();
  } catch {
    res.status(500).end();
  }
});

// ── GET /api/songs/:id/download ───────────────────────────────────────────────
// Download uses proxyStream (not redirect) to set Content-Disposition header.
router.get('/:id/download', async (req, res, next) => {
  try {
    const song = await prisma.song.findUnique({ where: { id: req.params.id } });
    if (!song)                return res.status(404).json({ error: 'Song not found' });
    if (!song.telegramFileId) return res.status(503).json({ error: 'Song audio not available' });

    const fileId = resolveFileId(song, 1);
    if (!fileId) return res.status(503).json({ error: 'File ID missing' });

    await telegram.downloadFile(fileId, req, res);
  } catch (err) {
    if (!res.headersSent) next(err);
  }
});

// ── GET /api/songs/:id/parts ──────────────────────────────────────────────────
// Returns part stream URLs so Flutter can queue sequential playback.
// Also pre-warms all part URLs and next songs.
router.get('/:id/parts', async (req, res, next) => {
  try {
    const song = await prisma.song.findUnique({ where: { id: req.params.id } });
    if (!song) return res.status(404).json({ error: 'Song not found' });

    const host     = req.get('x-forwarded-host') || req.get('host');
    const protocol = req.get('x-forwarded-proto') || req.protocol;
    const base     = `${protocol}://${host}/api/songs/${song.id}`;

    if (!song.telegramFileId)
      return res.status(503).json({ error: 'Song audio not available' });

    const raw  = song.telegramFileId;
    let parts  = [];

    if (raw.startsWith('[')) {
      try {
        const ids = JSON.parse(raw);
        parts = ids.map((_, idx) => ({
          partNumber:  idx + 1,
          streamUrl:   `${base}/stream?part=${idx + 1}`,
          downloadUrl: `${base}/download`,
        }));
      } catch {
        parts = [{ partNumber: 1, streamUrl: `${base}/stream`, downloadUrl: `${base}/download` }];
      }
    } else {
      parts = [{ partNumber: 1, streamUrl: `${base}/stream`, downloadUrl: `${base}/download` }];
    }

    res.json({
      success:     true,
      id:          song.id,
      title:       song.title,
      isMultiPart: song.partCount > 1,
      partCount:   song.partCount,
      duration:    song.duration,
      parts,
    });

    // Pre-warm all parts + next songs in the background
    setImmediate(() => preWarmAhead(song, 1));

  } catch (err) { next(err); }
});

// ── GET /api/songs/:id/resolve-url ────────────────────────────────────────────
// Returns the actual Telegram CDN URL for a given part.
// Used by Flutter to get a fresh URL after a 401 from Telegram CDN.
// Query param: ?part=N (default 1), ?refresh=1 (force cache evict)
router.get('/:id/resolve-url', async (req, res, next) => {
  try {
    const song = await prisma.song.findUnique({ where: { id: req.params.id } });
    if (!song)                return res.status(404).json({ error: 'Song not found' });
    if (!song.telegramFileId) return res.status(503).json({ error: 'Audio not available' });

    const partNum = parseInt(req.query.part || '1', 10);
    const fileId  = resolveFileId(song, partNum);
    if (!fileId) return res.status(503).json({ error: 'File ID missing' });

    const forceRefresh = req.query.refresh === '1';
    const url = forceRefresh
      ? await telegram.refreshUrl(fileId)
      : await telegram.getDirectUrl(fileId);

    res.json({ success: true, url, expiresInSeconds: 2400 });
  } catch (err) { next(err); }
});

// ── POST /api/songs ───────────────────────────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const { albumId, trackNumber, title, artist, telegramFileId, duration, partCount } = req.body;
    if (!albumId || !trackNumber || !title)
      return res.status(400).json({ error: 'albumId, trackNumber and title are required' });

    const song = await prisma.song.create({
      data: {
        albumId,
        trackNumber:    parseInt(trackNumber),
        title,
        artist:         artist         || null,
        telegramFileId: telegramFileId || null,
        duration:       duration       ? parseInt(duration)  : null,
        partCount:      partCount      ? parseInt(partCount) : 1,
      },
    });

    res.status(201).json({ success: true, data: song });
  } catch (err) { next(err); }
});

// ── PATCH /api/songs/:id ──────────────────────────────────────────────────────
router.patch('/:id', async (req, res, next) => {
  try {
    const { title, artist, telegramFileId, duration, partCount, isActive } = req.body;

    const song = await prisma.song.update({
      where: { id: req.params.id },
      data: {
        ...(title          != null && { title }),
        ...(artist         != null && { artist }),
        ...(telegramFileId != null && { telegramFileId }),
        ...(duration       != null && { duration: parseInt(duration) }),
        ...(partCount      != null && { partCount: parseInt(partCount) }),
        ...(isActive       != null && { isActive }),
      },
    });

    res.json({ success: true, data: song });
  } catch (err) { next(err); }
});

// ── DELETE /api/songs/:id ─────────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.song.update({ where: { id: req.params.id }, data: { isActive: false } });
    res.json({ success: true, message: 'Song deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;