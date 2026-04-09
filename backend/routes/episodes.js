// routes/episodes.js
const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

// ── Helper: resolve fileId for a given part number ───────────────────────────
function resolveFileId(episode, partNum = 1) {
  const raw = episode.telegramFileId;
  if (!raw) return null;

  // Multi-part: telegramFileId is a JSON array of file IDs
  if (raw.startsWith('[')) {
    try {
      const parts = JSON.parse(raw);
      const idx   = Math.min(Math.max(partNum - 1, 0), parts.length - 1);
      return parts[idx] || null;
    } catch {
      return raw; // malformed JSON — fall back to treating as single ID
    }
  }

  return raw;
}

// ── GET /api/episodes/:id/stream ─────────────────────────────────────────────
// Streams episode audio. Supports Range headers for Android seek.
// Query param: ?part=N  (1-based, default 1)
router.get('/:id/stream', async (req, res, next) => {
  try {
    const episode = await prisma.episode.findUnique({ where: { id: req.params.id } });
    if (!episode)                  return res.status(404).json({ error: 'Episode not found' });
    if (!episode.telegramFileId)   return res.status(503).json({ error: 'Episode audio not available yet. Run sync.' });

    const partNum = parseInt(req.query.part || '1', 10);
    if (isNaN(partNum) || partNum < 1 || partNum > episode.partCount) {
      return res.status(400).json({ error: `Invalid part. Episode has ${episode.partCount} part(s).` });
    }

    const fileId = resolveFileId(episode, partNum);
    if (!fileId) return res.status(503).json({ error: 'File ID missing — re-sync required.' });

    await telegram.proxyStream(fileId, req, res);
  } catch (err) {
    if (!res.headersSent) next(err);
  }
});

// ── GET /api/episodes/:id/download ──────────────────────────────────────────
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
// Returns part URLs so Android can queue sequential playback.
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

    const raw      = episode.telegramFileId;
    let parts      = [];

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