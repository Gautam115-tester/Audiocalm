# Audio Calm — Node.js Backend

Complete backend API for the Audio Calm Flutter app.
Stores audio files on Telegram, metadata in PostgreSQL.

---

## Folder Structure

```
backend/
├── server.js              ← Entry point
├── .env.example           ← Copy to .env and fill in values
├── package.json
├── routes/
│   ├── health.js          ← GET  /health
│   ├── series.js          ← GET  /api/series, /api/series/:id, /api/series/:id/episodes
│   ├── episodes.js        ← GET  /api/episodes/:id/stream  (Flutter player)
│   ├── albums.js          ← GET  /api/albums, /api/albums/:id, /api/albums/:id/songs
│   ├── songs.js           ← GET  /api/songs/:id/stream     (Flutter player)
│   ├── search.js          ← GET  /api/search?q=keyword
│   └── upload.js          ← POST /api/upload/*             (Admin: add content)
├── services/
│   ├── telegram.js        ← All Telegram Bot API calls
│   └── db.js              ← Prisma client singleton
└── prisma/
    ├── schema.prisma      ← Database schema
    └── seed.js            ← Sample data
```

---

## Setup

### 1. Install dependencies
```bash
npm install
```

### 2. Create your .env file
```bash
cp .env.example .env
```
Fill in:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_STORIES_CHANNEL_ID`
- `TELEGRAM_MUSIC_CHANNEL_ID`
- `TELEGRAM_COVERS_CHANNEL_ID`
- `DATABASE_URL`

### 3. Setup database
```bash
npx prisma migrate dev --name init
npx prisma generate
node prisma/seed.js    # optional sample data
```

### 4. Run locally
```bash
npm run dev
```

### 5. Test health check
```
GET http://localhost:3000/health
```

---

## All API Endpoints

### Flutter reads these:
| Method | Endpoint | Used by |
|--------|----------|---------|
| GET | /health | Connection check |
| GET | /api/series | Stories screen |
| GET | /api/series/:id | Series detail |
| GET | /api/series/:id/episodes | Episode list |
| GET | /api/albums | Music screen |
| GET | /api/albums/:id | Album detail |
| GET | /api/albums/:id/songs | Song list |
| GET | /api/episodes/:id/stream | Audio player |
| GET | /api/episodes/:id/stream?part=N | Multi-part player |
| GET | /api/episodes/:id/download | Offline download |
| GET | /api/songs/:id/stream | Audio player |
| GET | /api/songs/:id/stream?part=N | Multi-part player |
| GET | /api/songs/:id/download | Offline download |
| GET | /api/search?q=keyword | Search screen |

### Admin upload routes:
| Method | Endpoint | What it does |
|--------|----------|--------------|
| POST | /api/upload/series-cover | Upload cover image for a series |
| POST | /api/upload/album-cover | Upload cover image for an album |
| POST | /api/upload/episode-audio | Upload single episode audio |
| POST | /api/upload/episode-audio-multipart | Upload large episode (multiple parts) |
| POST | /api/upload/song-audio | Upload single song |
| POST | /api/upload/song-audio-multipart | Upload large song (multiple parts) |

### CRUD routes:
| Method | Endpoint | What it does |
|--------|----------|--------------|
| POST | /api/series | Create series |
| PATCH | /api/series/:id | Update series |
| DELETE | /api/series/:id | Soft delete series |
| POST | /api/albums | Create album |
| PATCH | /api/albums/:id | Update album |
| DELETE | /api/albums/:id | Soft delete album |
| POST | /api/episodes | Create episode record |
| PATCH | /api/episodes/:id | Update episode |
| DELETE | /api/episodes/:id | Soft delete episode |
| POST | /api/songs | Create song record |
| PATCH | /api/songs/:id | Update song |
| DELETE | /api/songs/:id | Soft delete song |

---

## How to Add Content (Step by Step)

### Add a new Story Series:
```bash
# 1. Create the series
POST /api/series
{ "title": "Sleep Stories", "description": "Bedtime stories" }
# → returns { id: "abc-123", ... }

# 2. Upload cover image
POST /api/upload/series-cover
form-data: file=cover.jpg, seriesId=abc-123
# → returns { seriesId, coverUrl }

# 3. Upload each episode
POST /api/upload/episode-audio
form-data: file=episode1.mp3, seriesId=abc-123, episodeNumber=1, title="The Forest"
# → returns { episodeId, telegramFileId, duration }
```

### Add a new Music Album:
```bash
# 1. Create the album
POST /api/albums
{ "title": "Nature Sounds", "artist": "Audio Calm" }
# → returns { id: "xyz-456", ... }

# 2. Upload cover image
POST /api/upload/album-cover
form-data: file=cover.jpg, albumId=xyz-456

# 3. Upload each song
POST /api/upload/song-audio
form-data: file=track1.mp3, albumId=xyz-456, trackNumber=1, title="Rain Forest"
```

---

## Deploy to Render.com

1. Push this folder to GitHub
2. Create a new **Web Service** on Render
3. Set **Build Command**: `npm install && npx prisma generate && npx prisma migrate deploy`
4. Set **Start Command**: `npm start`
5. Add all environment variables from `.env.example`
6. Deploy!

---

## Get Your Telegram Channel IDs

Forward any message from your channel to `@userinfobot` on Telegram.
It will reply with the channel ID (a negative number like `-1001234567890`).
