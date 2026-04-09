// routes/health.js
const express = require('express');
const router  = express.Router();
const prisma  = require('../services/db');

// GET /health
// Used by Render health-check and Android app startup diagnostics.
router.get('/', async (req, res) => {
  try {
    await prisma.$queryRaw`SELECT 1`;
    res.json({
      status:    'ok',
      timestamp: new Date().toISOString(),
      uptime:    process.uptime(),
      database:  'connected',
      telegram:  process.env.TELEGRAM_BOT_TOKEN ? 'configured' : 'missing',
    });
  } catch (err) {
    res.status(503).json({
      status:    'error',
      timestamp: new Date().toISOString(),
      database:  'disconnected',
      error:     err.message,
    });
  }
});

module.exports = router;