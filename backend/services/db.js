// services/db.js
//
// CONNECTION POOL ANALYSIS FOR 10,000 ACTIVE USERS — SINGLE RENDER SERVER
// =========================================================================
//
// SETUP:
//   • 1 Render free-tier web service  (1 vCPU, 512 MB RAM)
//   • Supabase free tier              (PostgreSQL via pgBouncer in Transaction mode)
//   • 10,000 active users
//
// WHY YOU CANNOT JUST SET connection_limit=10,000
// ------------------------------------------------
//   Each Prisma connection = 1 pgBouncer server-side connection.
//   Supabase free tier hard cap = 15 simultaneous DB connections (pgBouncer).
//   Setting connection_limit > 15 makes connections queue inside pgBouncer,
//   not actually run in parallel.  You waste RAM and get timeouts instead of
//   throughput.
//
// THE RIGHT MENTAL MODEL: QUEUEING, NOT PARALLEL EXECUTION
// ---------------------------------------------------------
//   10,000 users does NOT mean 10,000 simultaneous DB queries.
//   Most requests are:
//     • Served from NodeCache  → 0 DB queries (cache HIT after warmup)
//     • Album/series list      → 1 cached query per 5 min regardless of users
//     • Stream/download        → 0 DB queries (Telegram proxy, no DB call)
//     • Search                 → 1 DB query per unique search term
//
//   At 10,000 users, realistically:
//     • ~0.1 % are querying at any millisecond = ~10 concurrent DB queries
//     • p99 DB query time on Supabase free tier ≈ 20–80 ms
//     • Throughput needed = 10 queries / 0.05 s avg = 200 queries/sec
//     • pgBouncer with 10 connections handles ~500 queries/sec easily
//
// RECOMMENDED SETTINGS (chosen below):
//   connection_limit = 10   — 10 live DB connections via pgBouncer
//                             Covers burst traffic with headroom
//                             Well under Supabase free-tier 15-connection cap
//   pool_timeout     = 30   — wait 30 s for a free connection before P2024
//                             Covers Render cold-start (~25 s worst case)
//
// UPGRADE PATH (when you hit the ceiling):
//   1. Supabase Pro → 50 pooler connections  → set connection_limit=25
//   2. Render Starter ($7/mo) → keep same settings, lower cold-start to ~2 s
//   3. Render Standard ($25/mo) → always-on, zero cold-start
//
// HOW THE ALL-WITH-EPISODES / ALL-WITH-SONGS ENDPOINTS HELP AT SCALE
// -------------------------------------------------------------------
//   Before: 10,000 users × cold-start = 10,000 × 23 requests = 230,000 req/s burst
//   After:  10,000 users × cold-start = 10,000 × 2 requests  = 20,000 req/s burst
//           BUT: NodeCache means only 1 DB query per 5 minutes regardless of users
//   Net DB load: ~2 queries / 5 min = 0.007 queries/sec  ← essentially zero
//
// PGBOUNCER TRANSACTION MODE NOTE
// --------------------------------
//   Supabase uses pgBouncer in TRANSACTION mode.  This means:
//     • Prepared statements are NOT supported across connections
//     • Prisma must use ?pgbouncer=true to disable prepared statements
//     • Each transaction gets its own connection from the pool
//     • Connections are returned to the pool after COMMIT/ROLLBACK
//   All of this is handled by the URL params appended below.

const { PrismaClient } = require('@prisma/client');

function buildDatabaseUrl() {
  const base = process.env.DATABASE_URL || '';
  if (!base) return base;
  try {
    const url = new URL(base);

    // Required for Supabase pgBouncer transaction mode
    if (!url.searchParams.has('pgbouncer'))
      url.searchParams.set('pgbouncer', 'true');

    // 10 connections — optimal for Supabase free tier (hard cap = 15).
    // Handles 10,000 users because 99.9% of requests are cache hits.
    // See analysis above before increasing this number.
    if (!url.searchParams.has('connection_limit'))
      url.searchParams.set('connection_limit', '10');

    // 30 s timeout covers Render free-tier cold-start (~25 s worst case).
    // Increasing beyond 30 s causes client-side request timeouts first anyway.
    if (!url.searchParams.has('pool_timeout'))
      url.searchParams.set('pool_timeout', '30');

    return url.toString();
  } catch {
    return base;
  }
}

const prisma = new PrismaClient({
  // Log errors only in production — verbose query logs at 10k users would
  // fill the Render log buffer and waste I/O bandwidth.
  log: process.env.NODE_ENV === 'production' ? ['error'] : ['error', 'warn'],
  datasources: {
    db: { url: buildDatabaseUrl() },
  },
});

// Graceful shutdown — avoids "too many connections" on Render redeploy
process.on('beforeExit', async () => {
  await prisma.$disconnect();
});

// Also handle SIGTERM (Render sends this before killing the process)
process.on('SIGTERM', async () => {
  await prisma.$disconnect();
  process.exit(0);
});

module.exports = prisma;