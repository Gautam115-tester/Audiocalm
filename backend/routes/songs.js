// routes/songs.js
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

// ── GET /api/songs/:id/stream ─────────────────────────────────────────────────
// Streams song audio with Range header support for Android seek.
// Query param: ?part=N  (1-based, default 1)
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

    await telegram.proxyStream(fileId, req, res);
  } catch (err) {
    if (!res.headersSent) next(err);
  }
});

// ── HEAD /api/songs/:id/stream ────────────────────────────────────────────────
// Android audio player hits HEAD first to check size/type before buffering.
router.head('/:id/stream', async (req, res) => {
  try {
    const song = await prisma.song.findUnique({
      where:  { id: req.params.id },
      select: { id: true, telegramFileId: true, duration: true, partCount: true },
    });

    if (!song || !song.telegramFileId) return res.status(404).end();

    try { await telegram.getFileUrl(resolveFileId(song, 1)); } catch { /* ok, just headers */ }

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
// Returns part stream URLs so Android can queue sequential playback.
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