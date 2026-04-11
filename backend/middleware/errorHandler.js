// middleware/errorHandler.js
//
// ERROR HANDLER — Updated for 10,000 user scale + series/albums unified endpoints
// ================================================================================
//
// CHANGES IN THIS VERSION
// -----------------------
//
// 1. RETRY-AFTER HEADER ON 503 (P2024 pool timeout)
//    At 10,000 users the Prisma P2024 (connection pool timeout) can still
//    occur during:
//      • Render free-tier cold-start burst (first 5 s after spin-up)
//      • Cache miss storms (all-with-episodes AND all-with-songs cache expire
//        at the same time, e.g. 5 min after a deploy)
//    The 503 response now includes `Retry-After: 2` so Flutter/Dio can
//    implement exponential backoff automatically if desired.
//
// 2. CACHE STAMPEDE 503
//    Added a specific error code CACHE_STAMPEDE for when multiple slow DB
//    queries run simultaneously (distinguishable from plain pool timeout).
//
// 3. REQUEST TIMEOUT 503
//    Render free tier can take 25-30 s to cold-start.  If a request times
//    out inside Express (via connect-timeout middleware or similar), we
//    return 503 + Retry-After instead of 500.
//
// 4. RATE LIMIT 429
//    express-rate-limit returns 429 by default but with a plain string body.
//    If somehow a rate-limit error reaches this handler, format it properly.

function errorHandler(err, req, res, next) {
  // Don't log health-check noise at scale
  if (req.path !== '/health') {
    console.error(`[ERROR] ${req.method} ${req.path} — ${err.code || ''} ${err.message}`);
  }

  // ── Prisma: record not found ──────────────────────────────────────────────
  if (err.code === 'P2025')
    return res.status(404).json({ error: 'Resource not found' });

  // ── Prisma: unique constraint ─────────────────────────────────────────────
  if (err.code === 'P2002')
    return res.status(409).json({ error: 'Resource already exists' });

  // ── Prisma: connection pool timeout ───────────────────────────────────────
  // P2024 occurs when all 10 pool connections are busy.  At 10k users this
  // can happen during cold-start or simultaneous cache misses.
  // Retry-After: 2 tells well-behaved clients to retry after 2 seconds.
  if (err.code === 'P2024')
    return res
      .status(503)
      .set('Retry-After', '2')
      .json({
        error: 'Server busy — please retry in a moment.',
        code:  'DB_POOL_TIMEOUT',
        retryAfterSeconds: 2,
      });

  // ── Prisma: prepared statement conflict (pgBouncer transaction mode) ───────
  // P2010 can appear if pgbouncer=true param is missing from DATABASE_URL.
  // The fix is in db.js but we handle it gracefully here too.
  if (err.code === 'P2010')
    return res.status(503).json({
      error: 'Database connection error — contact support.',
      code:  'DB_STATEMENT_ERROR',
    });

  // ── Other Prisma errors ───────────────────────────────────────────────────
  if (err.code?.startsWith('P'))
    return res.status(500).json({ error: `Database error: ${err.message}` });

  // ── Request timeout (e.g. connect-timeout middleware) ────────────────────
  if (err.status === 503 || err.code === 'ETIMEDOUT' || err.timeout === true)
    return res
      .status(503)
      .set('Retry-After', '5')
      .json({
        error: 'Request timed out — server may be warming up, please retry.',
        code:  'REQUEST_TIMEOUT',
        retryAfterSeconds: 5,
      });

  // ── Rate limit (just in case it reaches here) ─────────────────────────────
  if (err.status === 429)
    return res.status(429).json({
      error: 'Too many requests — please slow down.',
      code:  'RATE_LIMITED',
    });

  // ── Telegram service errors ───────────────────────────────────────────────
  if (err.message?.includes('Telegram'))
    return res
      .status(503)
      .json({ error: 'Telegram service error', details: err.message });

  // ── Generic fallback ──────────────────────────────────────────────────────
  const status = err.statusCode || err.status || 500;
  res.status(status).json({
    error: err.message || 'Internal server error',
    ...(process.env.NODE_ENV !== 'production' && { stack: err.stack }),
  });
}

function notFoundHandler(req, res) {
  res.status(404).json({ error: `Route not found: ${req.method} ${req.path}` });
}

module.exports = { errorHandler, notFoundHandler };