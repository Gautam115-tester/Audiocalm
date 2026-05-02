// backend/routes/health.js
// FIXES:
// 1. Increased keep-alive ping frequency to every 5 min (was 10 min)
//    Render free tier spins down after ~10min of inactivity. 5min intervals
//    keep it consistently warm. Also pings Supabase every 5 min.
// 2. Health check now returns uptime + cache stats for debugging.
// 3. Popular URL warmer — every 50 minutes, re-resolves the most recent
//    songs and episodes so they never hit a cold Telegram cache when a user
//    taps play. Runs on a staggered schedule to avoid Telegram rate limits.

const express  = require('express');
const router   = express.Router();
const prisma   = require('../services/db');
const telegram = require('../services/telegram');

const DB_CHECK_TTL_MS   = 3 * 60 * 1000;  // cache DB status for 3 min
const DB_KEEPALIVE_MS   = 5 * 60 * 1000;  // ping every 5 min
const URL_WARM_MS       = 50 * 60 * 1000; // warm popular URLs every 50 min

let dbCache = { ok: null, checkedAt: 0 };
let requestCount = 0;

async function checkDb() {
  const now = Date.now();
  if (dbCache.ok !== null && now - dbCache.checkedAt < DB_CHECK_TTL_MS) {
    return dbCache.ok;
  }
  try {
    await prisma.$queryRaw`SELECT 1`;
    dbCache = { ok: true, checkedAt: now };
    return true;
  } catch {
    dbCache = { ok: false, checkedAt: now };
    return false;
  }
}

async function keepAlive() {
  try {
    await prisma.$queryRaw`SELECT 1`;
    dbCache = { ok: true, checkedAt: Date.now() };
    console.log('[KeepAlive] DB pinged successfully');
  } catch (err) {
    console.error('[KeepAlive] DB ping failed:', err.message);
    dbCache = { ok: false, checkedAt: Date.now() };
  }
}

// ── Popular URL warmer ────────────────────────────────────────────────────────
// Re-resolves Telegram CDN URLs for the most recent content every 50 minutes.
// This keeps the 55-min URL cache warm so users never hit a cold cache miss.
// Staggered at 300ms between requests to avoid Telegram rate limits.
async function warmPopularUrls() {
  try {
    // Get most recent songs (first track of each) and episodes
    const [recentSongs, recentEpisodes] = await Promise.all([
      prisma.song.findMany({
        where:   { isActive: true, telegramFileId: { not: null } },
        orderBy: { createdAt: 'desc' },
        take:    12,
        select:  { telegramFileId: true },
      }),
      prisma.episode.findMany({
        where:   { isActive: true, telegramFileId: { not: null } },
        orderBy: { episodeNumber: 'asc' },
        take:    12,
        select:  { telegramFileId: true },
      }),
    ]);

    const extractFirstFileId = (raw) => {
      if (!raw) return null;
      if (raw.startsWith('[')) {
        try { return JSON.parse(raw)[0]; } catch { return null; }
      }
      return raw;
    };

    const songFileIds    = recentSongs.map(s => extractFirstFileId(s.telegramFileId)).filter(Boolean);
    const episodeFileIds = recentEpisodes.map(e => extractFirstFileId(e.telegramFileId)).filter(Boolean);
    const allFileIds     = [...new Set([...songFileIds, ...episodeFileIds])].slice(0, 20);

    if (allFileIds.length === 0) return;

    console.log(`[WarmURLs] Warming ${allFileIds.length} popular URLs…`);
    telegram.warmUrlsBackground(allFileIds);
    console.log(`[WarmURLs] Background warm triggered for ${allFileIds.length} URLs`);
  } catch (err) {
    console.error('[WarmURLs] Failed:', err.message);
  }
}

// Start keep-alive after 10s startup delay, then every 5 min
setTimeout(() => {
  keepAlive();
  setInterval(keepAlive, DB_KEEPALIVE_MS);
}, 10_000);

// Start URL warming after 30s (after server has fully started), then every 50 min
// This ensures the most popular content is always warm in the Telegram URL cache
setTimeout(() => {
  warmPopularUrls();
  setInterval(warmPopularUrls, URL_WARM_MS);
}, 30_000);

// ── GET /health ───────────────────────────────────────────────────────────────
router.get('/', async (req, res) => {
  requestCount++;
  const now = Date.now();

  if (dbCache.ok !== null && now - dbCache.checkedAt < DB_CHECK_TTL_MS) {
    return res.json({
      status:    dbCache.ok ? 'ok' : 'degraded',
      timestamp: new Date().toISOString(),
      uptime:    process.uptime(),
      database:  dbCache.ok ? 'connected' : 'disconnected',
      telegram:  process.env.TELEGRAM_BOT_TOKEN ? 'configured' : 'missing',
      requests:  requestCount,
    });
  }

  const dbOk = await checkDb();
  res.status(dbOk ? 200 : 503).json({
    status:    dbOk ? 'ok' : 'error',
    timestamp: new Date().toISOString(),
    uptime:    process.uptime(),
    database:  dbOk ? 'connected' : 'disconnected',
    telegram:  process.env.TELEGRAM_BOT_TOKEN ? 'configured' : 'missing',
    requests:  requestCount,
  });
});

module.exports = router;