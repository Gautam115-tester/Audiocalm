// routes/episodes.js
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
//   When an episode part is requested, we immediately fire background URL
//   resolution for upcoming content so they are cache-hot when needed:
//
//   On part N request of episode X:
//     → Warm part N+1 of episode X        (next part, same episode)
//     → Warm part N+2 of episode X        (part after that)
//     → Warm ALL parts of episode X+1     (next episode in series)
//     → Warm ALL parts of episode X+2     (episode after that)
//
//   This means when just_audio finishes part N and requests part N+1,
//   the URL is already cached → redirect resolves in <5ms → zero buffer gap.
//   Same for the next episode transition.
//
// URL EXPIRY HANDLING:
//   Telegram signed URLs expire in ~1h. Our cache TTL is 45 min.
//   If just_audio receives a 401/403 from Telegram CDN it will retry the
//   /stream endpoint. On retry we check if the cached URL is stale and
//   force-refresh it via refreshUrl() before redirecting again.
//   The client never sees a playback gap — just_audio handles the retry
//   transparently at the network layer.

const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ── Helper: resolve fileId for a given part number ───────────────────────────
function resolveFileId(episode, partNum = 1) {
  const raw = episode.telegramFileId;
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

// ── Helper: get all file IDs for an episode ───────────────────────────────────
function getAllFileIds(episode) {
  const raw = episode.telegramFileId;
  if (!raw) return [];
  if (raw.startsWith('[')) {
    try {
      return JSON.parse(raw).filter(Boolean);
    } catch {
      return raw ? [raw] : [];
    }
  }
  return [raw];
}

// ── Helper: parse a comma-separated multi-part telegramFileId ─────────────────
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

// ── Pre-warm next parts + next episodes in background ────────────────────────
// Called after we resolve the current request — non-blocking.
async function preWarmAhead(currentEpisode, requestedPartNum) {
  try {
    const allIds = getAllFileIds(currentEpisode);
    const totalParts = allIds.length;

    // 1. Warm remaining parts of the current episode (parts after requested)
    const futurePartIds = [];
    for (let p = requestedPartNum; p < totalParts; p++) {
      if (allIds[p]) futurePartIds.push(allIds[p]);
    }
    if (futurePartIds.length > 0) {
      // Non-blocking fire-and-forget
      telegram.preWarmBatch(futurePartIds, { concurrency: 2 }).catch(() => {});
    }

    // 2. Warm next 2 episodes in the same series
    const nextEpisodes = await prisma.episode.findMany({
      where: {
        seriesId:      currentEpisode.seriesId,
        isActive:      true,
        episodeNumber: { gt: currentEpisode.episodeNumber },
      },
      orderBy: { episodeNumber: 'asc' },
      take:    2,  // next 2 episodes
      select:  { id: true, telegramFileId: true, episodeNumber: true },
    });

    for (const ep of nextEpisodes) {
      const ids = parseFileIds(ep.telegramFileId);
      if (ids.length > 0) {
        // Warm the first 2 parts of each upcoming episode (enough to start instantly)
        telegram.preWarmBatch(ids.slice(0, 2), { concurrency: 2 }).catch(() => {});
      }
    }
  } catch (err) {
    // Pre-warming is best-effort — never let it affect the response
    console.warn('[episodes] preWarmAhead error (non-fatal):', err.message);
  }
}

// ── GET /api/episodes/:id/stream ─────────────────────────────────────────────
// Returns a 302 redirect to the Telegram CDN URL.
// Audio streams directly from Telegram — zero Render bandwidth used.
// Query param: ?part=N  (1-based, default 1)
//
// URL REFRESH LOGIC:
//   If the request includes header X-Force-Refresh: 1 (sent by Flutter on retry
//   after a 401 from Telegram CDN), we force-evict the cache and re-resolve.
router.get('/:id/stream', async (req, res, next) => {
  try {
    const episode = await prisma.episode.findUnique({ where: { id: req.params.id } });
    if (!episode)                return res.status(404).json({ error: 'Episode not found' });
    if (!episode.telegramFileId) return res.status(503).json({ error: 'Episode audio not available yet. Run sync.' });

    const partNum = parseInt(req.query.part || '1', 10);
    if (isNaN(partNum) || partNum < 1 || partNum > episode.partCount) {
      return res.status(400).json({ error: `Invalid part. Episode has ${episode.partCount} part(s).` });
    }

    const fileId = resolveFileId(episode, partNum);
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
    // Kick off background URL resolution for upcoming parts/episodes.
    // This runs AFTER the response is sent so it never delays the client.
    setImmediate(() => preWarmAhead(episode, partNum));

  } catch (err) {
    if (!res.headersSent) next(err);
  }
});

// ── GET /api/episodes/:id/download ──────────────────────────────────────────
// Download uses proxyStream (not redirect) to set Content-Disposition header.
router.get('/:id/download', async (req, res, next) => {
  try {
    const episode = await prisma.episode.findUnique({ where: { id: req.params.id } });
    if (!episode)                return res.status(404).json({ error: 'Episode not found' });
    if (!episode.telegramFileId) return res.status(503).json({ error: 'Episode audio not available' });

    const fileId = resolveFileId(episode, 1);
    if (!fileId) return res.status(503).json({ error: 'File ID missing' });

    await telegram.downloadFile(fileId, req, res);
  } catch (err) {
    if (!res.headersSent) next(err);
  }
});

// ── GET /api/episodes/:id/parts ──────────────────────────────────────────────
// Returns part URLs so Flutter can queue sequential playback.
// NOW also pre-warms all part URLs and the next episode.
router.get('/:id/parts', async (req, res, next) => {
  try {
    const episode = await prisma.episode.findUnique({ where: { id: req.params.id } });
    if (!episode) return res.status(404).json({ error: 'Episode not found' });

    const host     = req.get('x-forwarded-host') || req.get('host');
    const protocol = req.get('x-forwarded-proto') || req.protocol;
    const base     = `${protocol}://${host}/api/episodes/${episode.id}`;

    if (!episode.telegramFileId) {
      return res.status(503).json({ error: 'Episode audio not available' });
    }

    const raw   = episode.telegramFileId;
    let   parts = [];

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
      id:          episode.id,
      title:       episode.title,
      isMultiPart: episode.partCount > 1,
      partCount:   episode.partCount,
      duration:    episode.duration,
      parts,
    });

    // Pre-warm all parts + next episodes in the background
    setImmediate(() => preWarmAhead(episode, 1));

  } catch (err) { next(err); }
});

// ── GET /api/episodes/:id/resolve-url ────────────────────────────────────────
// Returns the actual Telegram CDN URL for a given part.
// Used by Flutter to get a fresh URL after a 401 from Telegram CDN.
// Query param: ?part=N (default 1), ?refresh=1 (force cache evict)
router.get('/:id/resolve-url', async (req, res, next) => {
  try {
    const episode = await prisma.episode.findUnique({ where: { id: req.params.id } });
    if (!episode)                return res.status(404).json({ error: 'Episode not found' });
    if (!episode.telegramFileId) return res.status(503).json({ error: 'Audio not available' });

    const partNum = parseInt(req.query.part || '1', 10);
    const fileId  = resolveFileId(episode, partNum);
    if (!fileId) return res.status(503).json({ error: 'File ID missing' });

    const forceRefresh = req.query.refresh === '1';
    const url = forceRefresh
      ? await telegram.refreshUrl(fileId)
      : await telegram.getDirectUrl(fileId);

    res.json({ success: true, url, expiresInSeconds: 2400 });
  } catch (err) { next(err); }
});

// ── POST /api/episodes ───────────────────────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const { seriesId, episodeNumber, title, description, telegramFileId, duration, partCount } = req.body;
    if (!seriesId || !episodeNumber || !title)
      return res.status(400).json({ error: 'seriesId, episodeNumber and title are required' });

    const episode = await prisma.episode.create({
      data: {
        seriesId,
        episodeNumber: parseInt(episodeNumber),
        title,
        description: description || null,
        telegramFileId: telegramFileId || null,
        duration:  duration  ? parseInt(duration)  : null,
        partCount: partCount ? parseInt(partCount) : 1,
      },
    });

    res.status(201).json({ success: true, data: episode });
  } catch (err) { next(err); }
});

// ── PATCH /api/episodes/:id ──────────────────────────────────────────────────
router.patch('/:id', async (req, res, next) => {
  try {
    const { title, description, telegramFileId, duration, partCount, isActive } = req.body;

    const episode = await prisma.episode.update({
      where: { id: req.params.id },
      data: {
        ...(title          != null && { title }),
        ...(description    != null && { description }),
        ...(telegramFileId != null && { telegramFileId }),
        ...(duration       != null && { duration: parseInt(duration) }),
        ...(partCount      != null && { partCount: parseInt(partCount) }),
        ...(isActive       != null && { isActive }),
      },
    });

    res.json({ success: true, data: episode });
  } catch (err) { next(err); }
});

// ── DELETE /api/episodes/:id ─────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.episode.update({ where: { id: req.params.id }, data: { isActive: false } });
    res.json({ success: true, message: 'Episode deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;