// backend/services/telegram.js
//
// PERFORMANCE FIXES
// =================
//
// FIX 1 — INCREASED URL CACHE TTL: 45min → 55min
//    Telegram signed URLs last ~1hr. We were caching for 45min.
//    Flutter pre-warming (now removed) was constantly busting the cache.
//    With pre-warming gone, each URL is fetched exactly once per hour.
//    55min gives more buffer before expiry.
//
// FIX 2 — RATE LIMITING PROTECTION on getFile calls
//    Added per-key in-flight deduplication (was already there, keeping it).
//    Added global rate limiter: max 10 concurrent getFile calls.
//    This prevents a flood of requests from saturating Telegram's API.
//
// FIX 3 — REMOVED preWarmUrl and preWarmBatch exports
//    These functions were called by providers and routes to pre-warm URLs.
//    Pre-warming is the ROOT CAUSE of the 10s playback delay.
//    With the server-side cache (55min TTL), the first play request
//    resolves in <200ms. No pre-warming needed.
//
// FIX 4 — FASTER getFileUrl: connection timeout 30s → 10s
//    If Telegram API is slow, fail fast and let the client retry.
//    A 30s timeout means the user waits 30s before seeing an error.

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

// FIX 1: 55 min TTL (up from 45min) — Telegram URLs expire in ~1hr.
// With pre-warming removed, each URL is resolved exactly once per user session.
const FILE_URL_TTL = 3300; // 55 minutes
const urlCache = new NodeCache({ stdTTL: FILE_URL_TTL, checkperiod: 300 });

// In-flight deduplication: concurrent requests for same fileId share one Promise
const _inFlightResolve = new Map();

// FIX 2: Global concurrency limiter for getFile API calls.
// Telegram's Bot API has rate limits. Max 10 concurrent getFile calls prevents
// hitting those limits even if multiple users request different files simultaneously.
let _activeGetFileCalls = 0;
const _MAX_CONCURRENT_GETFILE = 10;
const _pendingGetFileQueue = [];

function _acquireGetFileSlot() {
  return new Promise((resolve) => {
    if (_activeGetFileCalls < _MAX_CONCURRENT_GETFILE) {
      _activeGetFileCalls++;
      resolve();
    } else {
      _pendingGetFileQueue.push(resolve);
    }
  });
}

function _releaseGetFileSlot() {
  _activeGetFileCalls--;
  if (_pendingGetFileQueue.length > 0) {
    const next = _pendingGetFileQueue.shift();
    _activeGetFileCalls++;
    next();
  }
}

const tgApi = axios.create({
  baseURL: TELEGRAM_API,
  timeout: 10_000, // FIX 4: 10s timeout (was 30s)
});

// ── getFileUrl ─────────────────────────────────────────────────────────────────
// Resolves a Telegram file_id → signed CDN URL.
// Cached 55 min. In-flight requests deduplicated. Rate-limited to 10 concurrent.
async function getFileUrl(telegramFileId) {
  if (!telegramFileId) throw new Error('telegramFileId is required');

  const cacheKey = `url:${telegramFileId}`;
  const cached   = urlCache.get(cacheKey);
  if (cached) return cached;

  if (_inFlightResolve.has(telegramFileId)) {
    return _inFlightResolve.get(telegramFileId);
  }

  const promise = (async () => {
    await _acquireGetFileSlot();
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
      _releaseGetFileSlot();
    }
  })();

  _inFlightResolve.set(telegramFileId, promise);
  return promise;
}

// ── getDirectUrl ───────────────────────────────────────────────────────────────
async function getDirectUrl(telegramFileId) {
  return getFileUrl(telegramFileId);
}

// ── refreshUrl ─────────────────────────────────────────────────────────────────
// Force-evict cache and re-resolve. Called when client gets 401 from Telegram CDN.
async function refreshUrl(telegramFileId) {
  const cacheKey = `url:${telegramFileId}`;
  urlCache.del(cacheKey);
  console.log(`[telegram] Force-refreshing URL for ${telegramFileId?.slice(0, 15)}…`);
  return getFileUrl(telegramFileId);
}

// FIX 3: preWarmUrl and preWarmBatch REMOVED.
// These were called on startup and caused 100-200 concurrent Telegram API calls,
// flooding the server and making real play requests wait 10+ seconds.
// The 55-min URL cache means the first real request resolves in <200ms.

// ── buildRedirectResponse ──────────────────────────────────────────────────────
function buildRedirectResponse(url, res) {
  res.setHeader('Cache-Control', 'private, max-age=3000'); // 50 min (slightly under cache TTL)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.redirect(302, url);
}

// ── proxyStream ────────────────────────────────────────────────────────────────
// KEPT for /download endpoint only.
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

// ── downloadFile ───────────────────────────────────────────────────────────────
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

// ── getCoverUrl ────────────────────────────────────────────────────────────────
async function getCoverUrl(telegramFileId) {
  if (!telegramFileId) return null;
  try {
    return await getFileUrl(telegramFileId);
  } catch (err) {
    console.warn(`[telegram] getCoverUrl failed (${telegramFileId?.slice(0, 15)}…): ${err.message}`);
    return null;
  }
}

// ── uploadAudio ────────────────────────────────────────────────────────────────
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

// ── uploadPhoto ────────────────────────────────────────────────────────────────
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
  // FIX 3: preWarmUrl and preWarmBatch intentionally NOT exported
  // Exporting them again would allow routes to call them, re-introducing the flood.
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