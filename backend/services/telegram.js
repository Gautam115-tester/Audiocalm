// services/telegram.js
//
// STREAMING ARCHITECTURE — DIRECT REDIRECT (NO PROXY)
// =====================================================
//
// PREVIOUS: Client → Render → Telegram → Render → Client
//   All audio bytes flowed through Render's 512MB free-tier instance.
//   Cold-start (25-50s) blocked the first audio chunk.
//   Render bandwidth consumed. 120s axios stream timeout risk.
//
// NOW: Client → Render (URL resolve only) → Client → Telegram CDN
//   Render resolves the Telegram signed URL (~50ms) and sends a 302.
//   Audio streams directly from Telegram's CDN — zero Render bandwidth.
//   Cold-start only affects the URL resolution, not the audio stream.
//   Telegram CDN = unlimited bandwidth, global edge, no buffering.
//
// KEY ADDITIONS:
//   getDirectUrl(fileId)          — resolve URL for redirect (cached 45 min)
//   preWarmUrl(fileId)            — fire-and-forget cache fill (no await needed)
//   preWarmBatch(fileIds)         — warm multiple URLs in parallel (next parts/tracks)
//   refreshUrl(fileId)            — force-evict cache and re-resolve (expired URL recovery)
//   buildRedirectResponse(url, res) — standard redirect with correct headers
//
// URL EXPIRY HANDLING:
//   Telegram signed URLs expire in ~1 hour.
//   urlCache TTL = 45 min → URLs always served fresh from cache.
//   Flutter's just_audio retries failed requests automatically.
//   On 401/403 from Telegram CDN, Flutter re-requests /stream → fresh 302.
//   refreshUrl() is also called by the /stream route when a cached URL 401s.

const axios = require('axios');
const NodeCache = require('node-cache');

const BOT_TOKEN          = process.env.TELEGRAM_BOT_TOKEN;
const STORIES_CHANNEL_ID = process.env.TELEGRAM_STORIES_CHANNEL_ID;
const MUSIC_CHANNEL_ID   = process.env.TELEGRAM_MUSIC_CHANNEL_ID;
const COVERS_CHANNEL_ID  = process.env.TELEGRAM_COVERS_CHANNEL_ID;

if (!BOT_TOKEN) {
  console.error('❌  TELEGRAM_BOT_TOKEN is missing — set it in .env');
  if (process.env.NODE_ENV === 'production') process.exit(1);
}

const TELEGRAM_API      = `https://api.telegram.org/bot${BOT_TOKEN}`;
const TELEGRAM_FILE_API = `https://api.telegram.org/file/bot${BOT_TOKEN}`;

// Cache file URLs for 45 min.
// Telegram signed URLs expire in ~1h → 45 min gives a safe buffer.
// On cache miss the URL is re-resolved and the client gets a fresh 302.
const FILE_URL_TTL = 2700; // 45 minutes in seconds
const urlCache = new NodeCache({ stdTTL: FILE_URL_TTL, checkperiod: 300 });

// In-flight deduplication: if two requests for the same fileId arrive
// simultaneously (e.g. concurrent part pre-warming), only one hits Telegram.
const _inFlightResolve = new Map();

const tgApi = axios.create({
  baseURL: TELEGRAM_API,
  timeout: 30_000,
});

// ── getFileUrl ────────────────────────────────────────────────────────────────
// Resolves a Telegram file_id → signed CDN download URL.
// Result cached 45 min. In-flight requests deduplicated.
async function getFileUrl(telegramFileId) {
  if (!telegramFileId) throw new Error('telegramFileId is required');

  const cacheKey = `url:${telegramFileId}`;
  const cached   = urlCache.get(cacheKey);
  if (cached) return cached;

  // Dedup: reuse in-flight promise if same fileId is being resolved right now
  if (_inFlightResolve.has(telegramFileId)) {
    return _inFlightResolve.get(telegramFileId);
  }

  const promise = (async () => {
    try {
      const res = await tgApi.get('/getFile', { params: { file_id: telegramFileId } });
      if (!res.data.ok) throw new Error(`Telegram getFile: ${res.data.description}`);

      const filePath = res.data.result?.file_path;
      if (!filePath) throw new Error('getFile returned empty file_path');

      const url = `${TELEGRAM_FILE_API}/${filePath}`;
      urlCache.set(cacheKey, url);
      return url;
    } catch (err) {
      if (err.response) {
        const s = err.response.status;
        const d = err.response.data;
        if (s === 400 && d?.description?.toLowerCase().includes('file is too big')) {
          throw Object.assign(new Error('FILE_TOO_LARGE'), { code: 'FILE_TOO_LARGE' });
        }
        throw new Error(`Telegram API HTTP ${s}: ${JSON.stringify(d)}`);
      }
      throw err;
    } finally {
      _inFlightResolve.delete(telegramFileId);
    }
  })();

  _inFlightResolve.set(telegramFileId, promise);
  return promise;
}

// ── getDirectUrl ──────────────────────────────────────────────────────────────
// Alias of getFileUrl — semantically used for redirect responses.
// Kept separate so callers are explicit about their intent.
async function getDirectUrl(telegramFileId) {
  return getFileUrl(telegramFileId);
}

// ── refreshUrl ────────────────────────────────────────────────────────────────
// Force-evict a cached URL and re-resolve from Telegram.
// Called when a client receives a 401/403 from Telegram CDN (URL expired early).
// Returns the fresh URL.
async function refreshUrl(telegramFileId) {
  const cacheKey = `url:${telegramFileId}`;
  urlCache.del(cacheKey);
  console.log(`[telegram] Force-refreshing URL for ${telegramFileId?.slice(0, 15)}…`);
  return getFileUrl(telegramFileId);
}

// ── preWarmUrl ────────────────────────────────────────────────────────────────
// Fire-and-forget: resolve and cache a URL in the background.
// Call this when you know a file will be needed soon (next part, next track).
// Never throws — errors are swallowed intentionally.
function preWarmUrl(telegramFileId) {
  if (!telegramFileId) return;
  const cacheKey = `url:${telegramFileId}`;
  if (urlCache.get(cacheKey)) return; // already cached, no-op
  getFileUrl(telegramFileId).catch((err) => {
    console.warn(`[telegram] preWarmUrl failed (${telegramFileId?.slice(0, 15)}…): ${err.message}`);
  });
}

// ── preWarmBatch ──────────────────────────────────────────────────────────────
// Pre-warm multiple file IDs in parallel with a small concurrency cap
// so we don't flood Telegram's getFile endpoint.
// fileIds: array of telegramFileId strings (nulls are filtered out)
async function preWarmBatch(fileIds, { concurrency = 3 } = {}) {
  if (!fileIds || fileIds.length === 0) return;
  const unique = [...new Set(fileIds.filter(Boolean))];
  // Filter already-cached
  const needed = unique.filter((id) => !urlCache.get(`url:${id}`));
  if (needed.length === 0) return;

  console.log(`[telegram] preWarmBatch: warming ${needed.length} URL(s)`);

  // Process in chunks of `concurrency`
  for (let i = 0; i < needed.length; i += concurrency) {
    const batch = needed.slice(i, i + concurrency);
    await Promise.allSettled(batch.map((id) => getFileUrl(id)));
    // Small delay between batches to avoid Telegram rate limiting
    if (i + concurrency < needed.length) {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
}

// ── buildRedirectResponse ─────────────────────────────────────────────────────
// Send a standard 302 redirect to a Telegram CDN URL.
// Cache-Control: private, max-age=2400 tells Flutter/Dio to reuse for 40 min
// (safe within the 45-min cache window).
function buildRedirectResponse(url, res) {
  res.setHeader('Cache-Control', 'private, max-age=2400');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.redirect(302, url);
}

// ── proxyStream ───────────────────────────────────────────────────────────────
// KEPT for the /download endpoint only — downloads need Content-Disposition.
// Stream routes now use buildRedirectResponse() instead.
// Also used as fallback if redirect is somehow not suitable.
async function proxyStream(telegramFileId, req, res) {
  let url;
  try {
    url = await getFileUrl(telegramFileId);
  } catch (err) {
    if (!res.headersSent) {
      if (err.code === 'FILE_TOO_LARGE') {
        return res.status(503).json({
          error: 'File exceeds Telegram Bot API 20 MB limit.',
          hint:  'Split into <20 MB parts named _part01, _part02 and re-upload.',
          code:  'FILE_TOO_LARGE',
        });
      }
      return res.status(503).json({ error: `Cannot resolve file: ${err.message}` });
    }
    return;
  }

  const rangeHeader = req.headers['range'];
  const upstreamHeaders = {
    'User-Agent': 'Mozilla/5.0 (compatible; AudioCalmProxy/2.0)',
    Accept: '*/*',
    ...(rangeHeader ? { Range: rangeHeader } : {}),
  };

  const fetchUpstream = (targetUrl) =>
    axios.get(targetUrl, {
      responseType:     'stream',
      timeout:          120_000,
      headers:          upstreamHeaders,
      validateStatus:   (s) => s >= 200 && s < 300,
      maxContentLength: 500 * 1024 * 1024,
      maxBodyLength:    500 * 1024 * 1024,
    });

  let tgRes;
  try {
    tgRes = await fetchUpstream(url);
  } catch (err) {
    const status = err.response?.status;
    if (status === 401 || status === 403) {
      urlCache.del(`url:${telegramFileId}`);
      try {
        const freshUrl = await getFileUrl(telegramFileId);
        tgRes = await fetchUpstream(freshUrl);
      } catch (retryErr) {
        if (!res.headersSent)
          res.status(502).json({ error: `Upstream retry failed: ${retryErr.message}` });
        return;
      }
    } else {
      if (!res.headersSent)
        res.status(502).json({ error: `Upstream error: ${err.message}` });
      return;
    }
  }

  const ct = tgRes.headers['content-type'] || 'audio/mpeg';
  res.setHeader('Content-Type',                ct);
  res.setHeader('Accept-Ranges',               tgRes.headers['accept-ranges'] || 'bytes');
  res.setHeader('Cache-Control',               'public, max-age=3600');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Expose-Headers',
    'Content-Length, Content-Range, Accept-Ranges, Content-Type');

  if (tgRes.headers['content-length'])  res.setHeader('Content-Length',  tgRes.headers['content-length']);
  if (tgRes.headers['content-range'])   res.setHeader('Content-Range',   tgRes.headers['content-range']);

  const httpStatus = tgRes.status === 206 ? 206 : 200;
  res.status(httpStatus);

  const destroy = () => { if (!tgRes.data.destroyed) tgRes.data.destroy(); };
  req.on('close',   destroy);
  req.on('aborted', destroy);

  tgRes.data.on('error', (e) => {
    console.error('[PROXY] stream error:', e.message);
    if (!res.headersSent) res.status(502).json({ error: 'Upstream stream error' });
    else res.destroy();
  });

  tgRes.data.pipe(res);
}

// ── downloadFile ──────────────────────────────────────────────────────────────
// For the /download endpoint — streams with attachment headers.
async function downloadFile(telegramFileId, req, res) {
  try {
    const url    = await getFileUrl(telegramFileId);
    const tgRes  = await axios.get(url, { responseType: 'stream' });

    res.setHeader('Content-Type',        tgRes.headers['content-type'] || 'audio/mpeg');
    res.setHeader('Content-Disposition', 'attachment');
    if (tgRes.headers['content-length'])
      res.setHeader('Content-Length', tgRes.headers['content-length']);

    res.status(200);
    tgRes.data.pipe(res);
  } catch (err) {
    console.error('downloadFile error:', err.message);
    if (!res.headersSent)
      res.status(500).json({ error: 'Failed to download file from Telegram' });
  }
}

// ── getCoverUrl ───────────────────────────────────────────────────────────────
// Returns a cached Telegram URL for a cover image.
// Returns null if fileId is falsy or getFileUrl fails.
async function getCoverUrl(telegramFileId) {
  if (!telegramFileId) return null;
  try {
    return await getFileUrl(telegramFileId);
  } catch (err) {
    console.warn(`[telegram] getCoverUrl failed (${telegramFileId?.slice(0, 15)}…): ${err.message}`);
    return null;
  }
}

// ── uploadAudio ───────────────────────────────────────────────────────────────
async function uploadAudio(filePath, channelId, caption = '') {
  const FormData = require('form-data');
  const fs       = require('fs');

  const form = new FormData();
  form.append('chat_id', channelId);
  form.append('audio',   fs.createReadStream(filePath));
  if (caption) form.append('caption', caption);

  const res = await axios.post(`${TELEGRAM_API}/sendAudio`, form, {
    headers:          form.getHeaders(),
    maxContentLength: Infinity,
    maxBodyLength:    Infinity,
    timeout:          300_000,
  });

  if (!res.data.ok) throw new Error(`Telegram sendAudio: ${res.data.description}`);

  const audio = res.data.result.audio;
  return { telegramFileId: audio.file_id, duration: audio.duration, fileSize: audio.file_size };
}

// ── uploadPhoto ───────────────────────────────────────────────────────────────
async function uploadPhoto(filePath, channelId, caption = '') {
  const FormData = require('form-data');
  const fs       = require('fs');

  const form = new FormData();
  form.append('chat_id', channelId);
  form.append('photo',   fs.createReadStream(filePath));
  if (caption) form.append('caption', caption);

  const res = await axios.post(`${TELEGRAM_API}/sendPhoto`, form, {
    headers:          form.getHeaders(),
    maxContentLength: Infinity,
    maxBodyLength:    Infinity,
    timeout:          120_000,
  });

  if (!res.data.ok) throw new Error(`Telegram sendPhoto: ${res.data.description}`);

  const photos    = res.data.result.photo;
  const bestPhoto = photos[photos.length - 1];
  return { telegramFileId: bestPhoto.file_id };
}

module.exports = {
  getFileUrl,
  getDirectUrl,
  refreshUrl,
  preWarmUrl,
  preWarmBatch,
  buildRedirectResponse,
  getCoverUrl,
  proxyStream,
  downloadFile,
  uploadAudio,
  uploadPhoto,
  STORIES_CHANNEL_ID,
  MUSIC_CHANNEL_ID,
  COVERS_CHANNEL_ID,
};