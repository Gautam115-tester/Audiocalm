// backend/services/db.js
//
// FIX: The "prepared statement already exists" (Postgres 42P05) error is caused
// by Render's PgBouncer running in transaction-pooling mode, which is incompatible
// with Prisma's default prepared statements. The solution is to disable prepared
// statements by adding ?pgbouncer=true&connection_limit=1 to the DATABASE_URL,
// OR by using the pgBouncerCompatibility flag in the Prisma datasource (schema.prisma).
//
// This file ensures a true singleton so only ONE PrismaClient ever exists per
// process — preventing multiple clients from flooding the pool.

const { PrismaClient } = require('@prisma/client');

const prisma = global.__prisma ?? new PrismaClient({
  log: process.env.NODE_ENV === 'development'
    ? ['query', 'error', 'warn']
    : ['error'],
});

if (process.env.NODE_ENV !== 'production') {
  global.__prisma = prisma;
}

module.exports = prisma;