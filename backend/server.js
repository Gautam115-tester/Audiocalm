// server.js
require('dotenv').config();

const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');
const path      = require('path');
const fs        = require('fs');

const healthRoutes  = require('./routes/health');
const seriesRoutes  = require('./routes/series');
const episodeRoutes = require('./routes/episodes');
const albumRoutes   = require('./routes/albums');
const songRoutes    = require('./routes/songs');
const searchRoutes  = require('./routes/search');
const uploadRoutes  = require('./routes/upload');
const syncRoutes    = require('./routes/sync');

const { errorHandler, notFoundHandler } = require('./middleware/errorHandler');
const { requireApiKey }                 = require('./middleware/auth');

const app  = express();
const PORT = parseInt(process.env.PORT || '3000', 10);

app.set('trust proxy', 1);

// ── CORS ──────────────────────────────────────────────────────────────────────
const allowedOrigins = process.env.ALLOWED_ORIGINS || '*';
const corsOptions = {
  origin:         allowedOrigins,
  methods:        ['GET', 'POST', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization', 'x-api-key'],
  exposedHeaders: ['Content-Length', 'Content-Range', 'Accept-Ranges', 'Content-Type'],
};
app.use(cors(corsOptions));
app.options('*', cors(corsOptions));

// ── Security ──────────────────────────────────────────────────────────────────
app.use(helmet());

// ── Logging ───────────────────────────────────────────────────────────────────
// Production: only log errors (4xx/5xx), skip health checks and successful GETs
// Development: log everything
if (process.env.NODE_ENV === 'production') {
  morgan.token('status', (req, res) => res.statusCode);
  app.use(morgan('short', {
    skip: (req, res) =>
      req.path === '/health' ||         // skip health check spam
      res.statusCode < 400,             // skip all successful requests
  }));
} else {
  app.use(morgan('dev'));
}

app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));



// ── Rate limiting ─────────────────────────────────────────────────────────────
const limiter = rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS)    || 15 * 60 * 1000,
  max:      parseInt(process.env.RATE_LIMIT_MAX_REQUESTS) || 300,
  message:  { error: 'Too many requests, please try again later.' },
  skip:     (req) => req.path.includes('/stream') || req.path.includes('/download'),
});
app.use('/api/', limiter);

// ── Public routes ─────────────────────────────────────────────────────────────
app.use('/health',       healthRoutes);
app.use('/api/series',   seriesRoutes);
app.use('/api/episodes', episodeRoutes);
app.use('/api/albums',   albumRoutes);
app.use('/api/songs',    songRoutes);
app.use('/api/search',   searchRoutes);

// ── Protected routes ──────────────────────────────────────────────────────────
app.use('/api/upload', requireApiKey, uploadRoutes);
app.use('/api/sync',   requireApiKey, syncRoutes);

// ── 404 & error handlers ──────────────────────────────────────────────────────
app.use(notFoundHandler);
app.use(errorHandler);

// ── Start ─────────────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  const configured = (key) => (process.env[key] ? '✅' : '❌ MISSING');
  console.log(`
╔══════════════════════════════════════════╗
║   🎵  AudioCalm API v2                    ║
║   Port : ${String(PORT).padEnd(32)}║
║   Env  : ${(process.env.NODE_ENV || 'development').padEnd(32)}║
╚══════════════════════════════════════════╝
  `);
  console.log(`  📡 Health    : http://localhost:${PORT}/health`);
  console.log(`  📊 Dashboard : http://localhost:${PORT}/dashboard`);
  console.log(`  🤖 Telegram  : ${configured('TELEGRAM_BOT_TOKEN')}`);
  console.log(`  🗄️  Database  : ${configured('DATABASE_URL')}`);
  console.log(`  🔑 API Key   : ${configured('API_SECRET_KEY')}`);
});

module.exports = app;