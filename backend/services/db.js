// services/db.js
// Singleton PrismaClient — prevents "prepared statement already exists" (PG error 42P05)
// which occurs when multiple PrismaClient instances share the same Postgres connection pool.
const { PrismaClient } = require('@prisma/client');

const prisma = global.__prisma ?? new PrismaClient({
  log: process.env.NODE_ENV === 'development'
    ? ['query', 'error', 'warn']
    : ['error'],
});

// In non-production, cache the instance on global so hot-reloads don't
// spin up a new client (and new prepared-statement namespace) each time.
if (process.env.NODE_ENV !== 'production') {
  global.__prisma = prisma;
}

module.exports = prisma;