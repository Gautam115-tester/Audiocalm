// backend/routes/episodes.js
//
// PERFORMANCE FIX: REMOVED preWarmAhead calls
// ============================================
//
// preWarmAhead() was called after every stream request to pre-resolve URLs
// for the next 2 episodes and all their parts. This sounds good in theory
// but caused a cascade:
//
// User taps play on episode 1:
//   → GET /api/episodes/ep1/stream
//   → preWarmAhead fires: resolves ep1 parts 2-N + ep2 all parts + ep3 all parts
//   → Each resolution = 1 Telegram getFile API call
//   → If ep2 has 3 parts and ep3 has 4 parts: 7 concurrent Telegram calls
//   → These compete with the NEXT user's play request
//   → With 10 concurrent users: 70 pre-warm calls + 10 real calls = 80 concurrent
//   → Telegram rate-limits → real play requests wait 10+ seconds
//
// FIX: Remove all preWarmAhead calls. The server-side URL cache (55 min TTL)
// means the SECOND play of any URL is instant. First play is <200ms.
// No pre-warming needed at this scale.
//
// For future scale (10k+ users): implement a Redis-backed URL cache shared
// across multiple server instances, with a background job that refreshes
// popular URLs before they expire.

const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

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

// ── GET /api/episodes/:id/stream ──────────────────────────────────────────────
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

    const forceRefresh = req.headers['x-force-refresh'] === '1' || req.query.refresh === '1';

    let url;
    if (forceRefresh) {
      url = await telegram.refreshUrl(fileId);
    } else {
      url = await telegram.getDirectUrl(fileId);
    }

    // 302 redirect to Telegram CDN — audio streams directly, zero Render bandwidth
    telegram.buildRedirectResponse(url, res);

    // FIX: NO preWarmAhead — removed entirely.
    // Pre-warming caused 10s playback delays by flooding the Telegram API.
    // The 55-min server cache handles repeat plays instantly.

  } catch (err) {
    if (!res.headersSent) next(err);
  }
});

// ── GET /api/episodes/:id/download ────────────────────────────────────────────
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

// ── GET /api/episodes/:id/parts ───────────────────────────────────────────────
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

    // FIX: NO preWarmAhead here either.

  } catch (err) { next(err); }
});

// ── GET /api/episodes/:id/resolve-url ─────────────────────────────────────────
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

    res.json({ success: true, url, expiresInSeconds: 3000 });
  } catch (err) { next(err); }
});

// ── POST /api/episodes ────────────────────────────────────────────────────────
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

// ── PATCH /api/episodes/:id ───────────────────────────────────────────────────
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

// ── DELETE /api/episodes/:id ──────────────────────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    await prisma.episode.update({ where: { id: req.params.id }, data: { isActive: false } });
    res.json({ success: true, message: 'Episode deactivated' });
  } catch (err) { next(err); }
});

module.exports = router;