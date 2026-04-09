// middleware/auth.js
// Single source of truth for API key authentication.
// Used by /api/upload and /api/sync routes.

function requireApiKey(req, res, next) {
  const key = req.headers['x-api-key'] || req.query.key;
  if (!key || key !== process.env.API_SECRET_KEY) {
    return res.status(401).json({ error: 'Unauthorized — valid x-api-key header required' });
  }
  next();
}

module.exports = { requireApiKey };
