// routes/health.js
const express = require('express');
const router  = express.Router();
const prisma  = require('../services/db');

// Cache DB check for 1 hour — avoids a DB round-trip on every Render ping.
const DB_CHECK_TTL_MS = 60 * 60 * 1000; // 1 hour
let dbCache = { ok: false, checkedAt: 0 };

async function checkDb() {
  const now = Date.now();
  if (now - dbCache.checkedAt < DB_CHECK_TTL_MS) return dbCache.ok;
  try {
    await prisma.$queryRaw`SELECT 1`;
    dbCache = { ok: true, checkedAt: now };
    return true;
  } catch {
    dbCache = { ok: false, checkedAt: now };
    return false;
  }
}

// GET /health
// Used by Render health-check and Android app startup diagnostics.
router.get('/', async (req, res) => {
  const dbOk = await checkDb();
  if (dbOk) {
    res.json({
      status:    'ok',
      timestamp: new Date().toISOString(),
      uptime:    process.uptime(),
      database:  'connected',
      telegram:  process.env.TELEGRAM_BOT_TOKEN ? 'configured' : 'missing',
    });
  } else {
    res.status(503).json({
      status:    'error',
      timestamp: new Date().toISOString(),
      database:  'disconnected',
    });
  }
});

module.exports = router;