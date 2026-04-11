// services/db.js
//
// FIX: connection_limit was 1. With 22 parallel Flutter requests all hitting the
// DB simultaneously, Prisma queued them against a single connection. Requests
// waiting more than pool_timeout=20s received a P2024 error, which errorHandler
// converted to HTTP 400 (now fixed to 503). 
//
// Supabase pgbouncer in transaction mode supports up to 15-20 connections per
// client on the free tier. Setting connection_limit=5 allows 5 concurrent DB
// queries, reducing P2024 pool timeouts dramatically while staying within
// Supabase's free-tier limits.
//
// Also increased pool_timeout from 20s to 30s to match the longer Render
// cold-start window.

const { PrismaClient } = require('@prisma/client');

function buildDatabaseUrl() {
  const base = process.env.DATABASE_URL || '';
  if (!base) return base;
  try {
    const url = new URL(base);
    if (!url.searchParams.has('pgbouncer'))        url.searchParams.set('pgbouncer', 'true');
    // FIX: was 1 — caused P2024 pool timeout under 22 parallel requests.
    // Supabase free tier supports ~15 simultaneous connections via pgbouncer.
    // 5 is a safe value that handles burst traffic without overloading Supabase.
    if (!url.searchParams.has('connection_limit')) url.searchParams.set('connection_limit', '8');
    // FIX: was 20s — increased to 30s to match Render cold-start window.
    if (!url.searchParams.has('pool_timeout'))     url.searchParams.set('pool_timeout', '40');
    return url.toString();
  } catch {
    return base;
  }
}

const prisma = new PrismaClient({
  log: ['error'],
  datasources: {
    db: { url: buildDatabaseUrl() },
  },
});

process.on('beforeExit', async () => {
  await prisma.$disconnect();
});

module.exports = prisma;