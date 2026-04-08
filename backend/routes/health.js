// routes/health.js
const express = require('express');
const router  = express.Router();
const prisma  = require('../services/db');

// GET /health
router.get('/', async (req, res) => {
  try {
    await prisma.$queryRaw`SELECT 1`;
    res.json({
      status: 'ok',
      timestamp: new Date().toISOString(),
      database: 'connected',
    });
  } catch (err) {
    res.status(503).json({
      status: 'error',
      timestamp: new Date().toISOString(),
      database: 'disconnected',
      error: err.message,
    });
  }
});

module.exports = router;
