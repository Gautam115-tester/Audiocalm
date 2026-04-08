// services/telegram.js
const axios = require('axios');

const BOT_TOKEN          = process.env.TELEGRAM_BOT_TOKEN;
const STORIES_CHANNEL_ID = process.env.TELEGRAM_STORIES_CHANNEL_ID;
const MUSIC_CHANNEL_ID   = process.env.TELEGRAM_MUSIC_CHANNEL_ID;
const COVERS_CHANNEL_ID  = process.env.TELEGRAM_COVERS_CHANNEL_ID;

const TELEGRAM_API = `https://api.telegram.org/bot${BOT_TOKEN}`;
const TELEGRAM_FILE_API = `https://api.telegram.org/file/bot${BOT_TOKEN}`;

// ── Validate config on startup ────────────────────────────────────────────────
if (!BOT_TOKEN) {
  console.error('❌ TELEGRAM_BOT_TOKEN is missing from .env');
  process.exit(1);
}

// ── Get file download URL from Telegram ──────────────────────────────────────
async function getFileUrl(telegramFileId) {
  try {
    const response = await axios.get(`${TELEGRAM_API}/getFile`, {
      params: { file_id: telegramFileId },
    });

    if (!response.data.ok) {
      throw new Error(`Telegram getFile failed: ${response.data.description}`);
    }

    const filePath = response.data.result.file_path;
    return `${TELEGRAM_FILE_API}/${filePath}`;
  } catch (err) {
    console.error('❌ getFileUrl error:', err.message);
    throw err;
  }
}

// ── Stream audio file from Telegram to Flutter ────────────────────────────────
// Used for: /api/songs/:id/stream  and  /api/episodes/:id/stream
async function streamFile(telegramFileId, res, rangeHeader = null) {
  try {
    const fileUrl = await getFileUrl(telegramFileId);

    const headers = {};
    if (rangeHeader) {
      headers['Range'] = rangeHeader;
    }

    const telegramResponse = await axios.get(fileUrl, {
      responseType: 'stream',
      headers,
    });

    // Forward content headers to Flutter
    res.set('Content-Type', telegramResponse.headers['content-type'] || 'audio/mpeg');
    res.set('Accept-Ranges', 'bytes');

    if (telegramResponse.headers['content-length']) {
      res.set('Content-Length', telegramResponse.headers['content-length']);
    }
    if (telegramResponse.headers['content-range']) {
      res.set('Content-Range', telegramResponse.headers['content-range']);
      res.status(206); // Partial Content
    } else {
      res.status(200);
    }

    telegramResponse.data.pipe(res);
  } catch (err) {
    console.error('❌ streamFile error:', err.message);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Failed to stream file from Telegram' });
    }
  }
}

// ── Download full file buffer from Telegram ───────────────────────────────────
// Used for: /api/songs/:id/download  and  /api/episodes/:id/download
async function downloadFile(telegramFileId, res) {
  try {
    const fileUrl = await getFileUrl(telegramFileId);

    const telegramResponse = await axios.get(fileUrl, {
      responseType: 'stream',
    });

    res.set('Content-Type', 'audio/mpeg');
    res.set('Content-Disposition', 'attachment');

    if (telegramResponse.headers['content-length']) {
      res.set('Content-Length', telegramResponse.headers['content-length']);
    }

    res.status(200);
    telegramResponse.data.pipe(res);
  } catch (err) {
    console.error('❌ downloadFile error:', err.message);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Failed to download file from Telegram' });
    }
  }
}

// ── Upload audio file to a Telegram channel ───────────────────────────────────
// Returns the telegramFileId to store in your database
async function uploadAudio(filePath, channelId, caption = '') {
  try {
    const FormData = require('form-data');
    const fs = require('fs');

    const form = new FormData();
    form.append('chat_id', channelId);
    form.append('audio', fs.createReadStream(filePath));
    if (caption) form.append('caption', caption);

    const response = await axios.post(`${TELEGRAM_API}/sendAudio`, form, {
      headers: form.getHeaders(),
      maxContentLength: Infinity,
      maxBodyLength: Infinity,
    });

    if (!response.data.ok) {
      throw new Error(`Telegram upload failed: ${response.data.description}`);
    }

    const audio = response.data.result.audio;
    return {
      telegramFileId: audio.file_id,
      duration: audio.duration,       // seconds
      fileSize: audio.file_size,
    };
  } catch (err) {
    console.error('❌ uploadAudio error:', err.message);
    throw err;
  }
}

// ── Upload cover image to a Telegram channel ──────────────────────────────────
// Returns the telegramFileId for the cover photo
async function uploadPhoto(filePath, channelId, caption = '') {
  try {
    const FormData = require('form-data');
    const fs = require('fs');

    const form = new FormData();
    form.append('chat_id', channelId);
    form.append('photo', fs.createReadStream(filePath));
    if (caption) form.append('caption', caption);

    const response = await axios.post(`${TELEGRAM_API}/sendPhoto`, form, {
      headers: form.getHeaders(),
      maxContentLength: Infinity,
      maxBodyLength: Infinity,
    });

    if (!response.data.ok) {
      throw new Error(`Telegram photo upload failed: ${response.data.description}`);
    }

    // Get the highest resolution version
    const photos = response.data.result.photo;
    const bestPhoto = photos[photos.length - 1];

    return {
      telegramFileId: bestPhoto.file_id,
    };
  } catch (err) {
    console.error('❌ uploadPhoto error:', err.message);
    throw err;
  }
}

// ── Build a public cover URL ──────────────────────────────────────────────────
// Flutter uses this as coverUrl in AlbumModel / SeriesModel
async function getCoverUrl(telegramFileId) {
  if (!telegramFileId) return null;
  try {
    return await getFileUrl(telegramFileId);
  } catch {
    return null;
  }
}

module.exports = {
  streamFile,
  downloadFile,
  uploadAudio,
  uploadPhoto,
  getCoverUrl,
  getFileUrl,
  STORIES_CHANNEL_ID,
  MUSIC_CHANNEL_ID,
  COVERS_CHANNEL_ID,
};
