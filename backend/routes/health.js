// routes/health.js
// Keeps both Render and Supabase alive:
//   - Render:   an external cron (cron-job.org) pings GET /health every 10 min
//               to prevent the free tier from spinning down
//   - Supabase: pings the DB every 10 min to prevent Supabase pausing the
//               project after 1 week of inactivity (free tier limitation)

const express = require('express');
const router  = express.Router();
const prisma  = require('../services/db');

const DB_CHECK_TTL_MS   = 5 * 60 * 1000;  // cache DB status for 5 min
const DB_KEEPALIVE_MS   = 10 * 60 * 1000; // ping Supabase every 10 min

let dbCache = { ok: null, checkedAt: 0 };

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

// ── Supabase keep-alive ping ──────────────────────────────────────────────────
// Supabase free tier pauses projects after 1 week of no DB activity.
// This runs a lightweight query every 10 min to prevent that.
async function keepSupabaseAlive() {
  try {
    await prisma.$queryRaw`SELECT 1`;
    console.log('[KeepAlive] Supabase pinged successfully');
    dbCache = { ok: true, checkedAt: Date.now() };
  } catch (err) {
    console.error('[KeepAlive] Supabase ping failed:', err.message);
    dbCache = { ok: false, checkedAt: Date.now() };
  }
}

// Start pinging Supabase every 10 minutes after a 15s startup delay
setTimeout(() => {
  keepSupabaseAlive(); // first ping shortly after startup
  setInterval(keepSupabaseAlive, DB_KEEPALIVE_MS);
}, 15_000);

// ── GET /health ───────────────────────────────────────────────────────────────
// Render health check + external cron target to keep server alive.
// Responds instantly from cache — no extra DB round-trip on every ping.
router.get('/', async (req, res) => {
  const now = Date.now();

  // Respond from cache if fresh
  if (dbCache.ok !== null && now - dbCache.checkedAt < DB_CHECK_TTL_MS) {
    return res.json({
      status:    dbCache.ok ? 'ok' : 'degraded',
      timestamp: new Date().toISOString(),
      uptime:    process.uptime(),
      database:  dbCache.ok ? 'connected' : 'disconnected',
      telegram:  process.env.TELEGRAM_BOT_TOKEN ? 'configured' : 'missing',
    });
  }

  // No cache yet — live check (only on very first ping after cold start)
  const dbOk = await checkDb();
  res.status(dbOk ? 200 : 503).json({
    status:    dbOk ? 'ok' : 'error',
    timestamp: new Date().toISOString(),
    uptime:    process.uptime(),
    database:  dbOk ? 'connected' : 'disconnected',
    telegram:  process.env.TELEGRAM_BOT_TOKEN ? 'configured' : 'missing',
  });
});

module.exports = router;