// lib/core/constants/api_constants.dart

class ApiConstants {
  ApiConstants._();

  static const String baseUrl = 'https://audiowave-2.onrender.com';

  // ── List endpoints ─────────────────────────────────────────────────────────
  static const String series  = '/api/series';
  static const String albums  = '/api/albums';
  static const String search  = '/api/search';
  static const String health  = '/health';

  // ── Batch / combined endpoints (single DB query, zero fan-out) ────────────
  //
  // These replace the old "fetch list → fetch each detail + children" pattern.
  //
  // allAlbumsWithSongs:    GET /api/albums/all-with-songs
  //   Returns all albums with their songs embedded.
  //   Replaces: 1 × /api/albums  +  N × /api/albums/:id/songs
  //   Before: 1 + 2N = 23 requests (11 albums)
  //   After:  1 request
  //
  // allSeriesWithEpisodes: GET /api/series/all-with-episodes
  //   Returns all series with their episodes embedded.
  //   Replaces: 1 × /api/series  +  N × /api/series/:id  +  N × /api/series/:id/episodes
  //   Before: 1 + 2N requests
  //   After:  1 request
  static const String allAlbumsWithSongs      = '/api/albums/all-with-songs';
  static const String allSeriesWithEpisodes   = '/api/series/all-with-episodes';

  // ── Detail endpoints (used for deep-link navigation + admin) ─────────────
  static String seriesById(String id)     => '/api/series/$id';
  static String seriesEpisodes(String id) => '/api/series/$id/episodes';
  static String albumById(String id)      => '/api/albums/$id';
  static String albumSongs(String id)     => '/api/albums/$id/songs';

  // ── Stream / download endpoints ───────────────────────────────────────────
  static String episodeStream(String id)   => '/api/episodes/$id/stream';
  static String episodeParts(String id)    => '/api/episodes/$id/parts';
  static String episodeDownload(String id) => '/api/episodes/$id/download';
  static String songStream(String id)      => '/api/songs/$id/stream';
  static String songParts(String id)       => '/api/songs/$id/parts';
  static String songDownload(String id)    => '/api/songs/$id/download';

  // ── Timeouts ───────────────────────────────────────────────────────────────
  // connectTimeout: 10 s — fail fast if Render hasn't responded at all.
  // receiveTimeout: 45 s — Render free tier cold-start can take ~50 s;
  //                        60 s gives a comfortable buffer.
  // Streaming uses a separate longer timeout set in audio_handler.dart.
  static const int connectTimeout = 10000;  // 10 s
  static const int receiveTimeout = 60000;  // 45 s
}