// middleware/errorHandler.js

function errorHandler(err, req, res, next) {
  console.error(`[ERROR] ${req.method} ${req.path} —`, err.message);

  // Prisma: record not found
  if (err.code === 'P2025')
    return res.status(404).json({ error: 'Resource not found' });

  // Prisma: unique constraint
  if (err.code === 'P2002')
    return res.status(409).json({ error: 'Resource already exists' });

  // Other Prisma errors
  if (err.code?.startsWith('P'))
    return res.status(400).json({ error: `Database error: ${err.message}` });

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
