// middleware/errorHandler.js
//
// FIX: Prisma P2024 (connection pool timeout) was returning HTTP 400
// "Database error: Timed out fetching a new connection from the connection pool"
// which Dio logged as "status code 400 - bad syntax". This was caused by 22
// parallel Flutter requests exhausting the single DB connection (connection_limit=1).
// P2024 is a server-side resource exhaustion, not a client error → should be 503.

function errorHandler(err, req, res, next) {
  console.error(`[ERROR] ${req.method} ${req.path} —`, err.message);

  // Prisma: record not found
  if (err.code === 'P2025')
    return res.status(404).json({ error: 'Resource not found' });

  // Prisma: unique constraint violation
  if (err.code === 'P2002')
    return res.status(409).json({ error: 'Resource already exists' });

  // FIX: Prisma P2024 = connection pool timeout under high concurrency.
  // This is a server-side resource issue, NOT a client bad-request error.
  // Was returning 400 (misleading); now returns 503 with retry guidance.
  if (err.code === 'P2024')
    return res.status(503).json({
      error: 'Server is busy — please retry in a moment.',
      code:  'DB_POOL_TIMEOUT',
    });

  // Other Prisma errors (P1xxx, P2xxx, P3xxx etc.) — genuine DB/query errors
  if (err.code?.startsWith('P'))
    return res.status(500).json({ error: `Database error: ${err.message}` });

  // Telegram service errors
  if (err.message?.includes('Telegram'))
    return res.status(503).json({ error: 'Telegram service error', details: err.message });

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