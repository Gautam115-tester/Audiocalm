// server.js
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');

const seriesRoutes    = require('./routes/series');
const episodesRoutes  = require('./routes/episodes');
const albumsRoutes    = require('./routes/albums');
const songsRoutes     = require('./routes/songs');
const searchRoutes    = require('./routes/search');
const uploadRoutes    = require('./routes/upload');
const healthRoutes    = require('./routes/health');

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Security & logging ────────────────────────────────────────────────────────
app.use(helmet());
app.use(morgan('combined'));
app.use(cors({ origin: process.env.ALLOWED_ORIGINS || '*' }));        // tighten in production if needed
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// ── Rate limiting ─────────────────────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS) || 15 * 60 * 1000,
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS) || 300,
  message: { error: 'Too many requests, please try again later.' },
});
app.use('/api/', limiter);

// ── Routes ────────────────────────────────────────────────────────────────────
app.use('/health',        healthRoutes);
app.use('/api/series',    seriesRoutes);
app.use('/api/episodes',  episodesRoutes);
app.use('/api/albums',    albumsRoutes);
app.use('/api/songs',     songsRoutes);
app.use('/api/search',    searchRoutes);
app.use('/api/upload',    uploadRoutes);

// ── 404 handler ───────────────────────────────────────────────────────────────
app.use((req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

// ── Global error handler ──────────────────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error', message: err.message });
});

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`🚀 Audio Calm API running on port ${PORT}`);
  console.log(`📡 Health check: http://localhost:${PORT}/health`);
});

module.exports = app;
