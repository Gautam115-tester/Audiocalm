// services/telegram.js
// Unified Telegram service:
//   - File URL resolution with NodeCache (45-min TTL, auto-refresh on 401/403)
//   - Proxy streaming with Range header support (seek support for Android)
//   - File download / upload helpers
//   - Cover URL helper used by routes

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

// Cache file URLs for 45 min. Telegram signed URLs typically expire in ~1 h,
// so 45 min gives a comfortable buffer before expiry.
const FILE_URL_TTL = 2700; // seconds
const urlCache = new NodeCache({ stdTTL: FILE_URL_TTL, checkperiod: 300 });

const tgApi = axios.create({
  baseURL: TELEGRAM_API,
  timeout: 30_000,
});

// ── getFileUrl ────────────────────────────────────────────────────────────────
// Resolves a Telegram file_id → temporary download URL.
// Result is cached 45 min to reduce Telegram API calls.
async function getFileUrl(telegramFileId) {
  if (!telegramFileId) throw new Error('telegramFileId is required');

  const cacheKey = `url:${telegramFileId}`;
  const cached   = urlCache.get(cacheKey);
  if (cached) return cached;

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
  }
}

// ── proxyStream ───────────────────────────────────────────────────────────────
// Proxies a Telegram audio file to the HTTP response.
// Forwards Range headers → Android just_audio can seek without re-downloading.
// Auto-refreshes the URL on 401/403 (expired signed URL).
async function proxyStream(telegramFileId, req, res) {
  // Resolve URL (cached)
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
      // Signed URL expired — delete from cache and retry once
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

  // Forward headers
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

  console.log(
    `[PROXY] ${httpStatus} | ${ct} | ` +
    `${tgRes.headers['content-length'] || '?'} bytes | ` +
    `Range: ${rangeHeader || 'none'}`
  );

  // Clean up upstream stream if client disconnects early
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
// For the /download endpoint — streams the full file with attachment headers.
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
// Returns a fresh (cached) Telegram URL for a cover image.
// Returns null if fileId is falsy or getFileUrl fails (never throws).
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
  const bestPhoto = photos[photos.length - 1]; // highest resolution
  return { telegramFileId: bestPhoto.file_id };
}

module.exports = {
  getFileUrl,
  getCoverUrl,
  proxyStream,
  downloadFile,
  uploadAudio,
  uploadPhoto,
  STORIES_CHANNEL_ID,
  MUSIC_CHANNEL_ID,
  COVERS_CHANNEL_ID,
};