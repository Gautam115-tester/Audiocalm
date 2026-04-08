// prisma/seed.js
// Run with: node prisma/seed.js
// Creates sample series and album records (no audio, just metadata)

const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();

async function main() {
  console.log('🌱 Seeding database...');

  // Sample series
  const series1 = await prisma.series.upsert({
    where: { id: 'seed-series-1' },
    update: {},
    create: {
      id:          'seed-series-1',
      title:       'Deep Sleep Stories',
      description: 'Calming bedtime stories to help you fall asleep',
      isActive:    true,
    },
  });

  const series2 = await prisma.series.upsert({
    where: { id: 'seed-series-2' },
    update: {},
    create: {
      id:          'seed-series-2',
      title:       'Morning Meditations',
      description: 'Start your day with peace and clarity',
      isActive:    true,
    },
  });

  // Sample album
  const album1 = await prisma.album.upsert({
    where: { id: 'seed-album-1' },
    update: {},
    create: {
      id:       'seed-album-1',
      title:    'Nature Sounds',
      artist:   'Audio Calm',
      isActive: true,
    },
  });

  console.log('✅ Seeded:');
  console.log('  Series:', series1.title, '|', series2.title);
  console.log('  Album: ', album1.title);
  console.log('');
  console.log('Next steps:');
  console.log('  1. POST /api/upload/series-cover   → upload cover images');
  console.log('  2. POST /api/upload/episode-audio  → upload audio files');
  console.log('  3. POST /api/upload/album-cover    → upload album covers');
  console.log('  4. POST /api/upload/song-audio     → upload songs');
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(() => prisma.$disconnect());
