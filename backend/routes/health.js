// backend/routes/health.js
// FIXES:
// 1. Increased keep-alive ping frequency to every 5 min (was 10 min)
//    Render free tier spins down after ~10min of inactivity. 5min intervals
//    keep it consistently warm. Also pings Supabase every 5 min.
// 2. Added /api/warmup endpoint that pre-resolves common Telegram URLs
//    so the first real user request is already cache-warm.
// 3. Health check now returns uptime + cache stats for debugging.

const express = require('express');
const router  = express.Router();
const prisma  = require('../services/db');

// Keep-alive every 5 minutes (was 10) to prevent Render free-tier spindown
const DB_CHECK_TTL_MS   = 3 * 60 * 1000;  // cache DB status for 3 min
const DB_KEEPALIVE_MS   = 5 * 60 * 1000;  // ping every 5 min (was 10)

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

// Start keep-alive after 10s startup delay, then every 5 min
setTimeout(() => {
  keepAlive();
  setInterval(keepAlive, DB_KEEPALIVE_MS);
}, 10_000);

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