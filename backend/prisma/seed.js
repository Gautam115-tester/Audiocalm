// prisma/seed.js
// Run: node prisma/seed.js
// Creates sample records for local development. Safe to re-run (upsert).

const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

async function main() {
  console.log('🌱 Seeding database…');

  const series1 = await prisma.series.upsert({
    where:  { id: 'seed-series-1' },
    update: {},
    create: { id: 'seed-series-1', title: 'Deep Sleep Stories', description: 'Calming bedtime stories', isActive: true },
  });

  const series2 = await prisma.series.upsert({
    where:  { id: 'seed-series-2' },
    update: {},
    create: { id: 'seed-series-2', title: 'Morning Meditations', description: 'Start your day with peace', isActive: true },
  });

  const album1 = await prisma.album.upsert({
    where:  { id: 'seed-album-1' },
    update: {},
    create: { id: 'seed-album-1', title: 'Nature Sounds', artist: 'Audio Calm', isActive: true },
  });

  console.log('✅ Seeded:', series1.title, '|', series2.title, '|', album1.title);
  console.log('\nNext steps:');
  console.log('  POST /api/upload/series-cover  — upload cover images (x-api-key required)');
  console.log('  POST /api/upload/episode-audio — upload episode audio');
  console.log('  POST /api/sync/music           — auto-sync from Telegram music channel');
  console.log('  POST /api/sync/covers          — auto-sync cover art from Telegram covers channel');
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(() => prisma.$disconnect());