// services/db.js
const { PrismaClient } = require('@prisma/client');

function buildDatabaseUrl() {
  const base = process.env.DATABASE_URL || '';
  if (!base) return base;
  try {
    const url = new URL(base);
    if (!url.searchParams.has('pgbouncer'))        url.searchParams.set('pgbouncer', 'true');
    if (!url.searchParams.has('connection_limit')) url.searchParams.set('connection_limit', '1');
    if (!url.searchParams.has('pool_timeout'))     url.searchParams.set('pool_timeout', '20');
    return url.toString();
  } catch {
    return base;
  }
}

const prisma = new PrismaClient({
  // Only log real errors — no query/warn spam in Render logs
  log: ['error'],
  datasources: {
    db: { url: buildDatabaseUrl() },
  },
});

process.on('beforeExit', async () => {
  await prisma.$disconnect();
});

module.exports = prisma;