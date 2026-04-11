// lib/core/constants/api_constants.dart

class ApiConstants {
  ApiConstants._();

  static const String baseUrl = 'https://audiowave-2.onrender.com';

  static const String series  = '/api/series';
  static const String albums  = '/api/albums';
  static const String search  = '/api/search';
  static const String health  = '/health';
  static const String allAlbumsWithSongs = '/api/albums/all-with-songs';

  static String seriesById(String id)     => '/api/series/$id';
  static String seriesEpisodes(String id) => '/api/series/$id/episodes';
  static String albumById(String id)      => '/api/albums/$id';
  static String albumSongs(String id)     => '/api/albums/$id/songs';
  static String episodeStream(String id)  => '/api/episodes/$id/stream';
  static String episodeParts(String id)   => '/api/episodes/$id/parts';
  static String episodeDownload(String id)=> '/api/episodes/$id/download';
  static String songStream(String id)     => '/api/songs/$id/stream';
  static String songParts(String id)      => '/api/songs/$id/parts';
  static String songDownload(String id)   => '/api/songs/$id/download';
  

  // PERF FIX: 10s connect (was 30s), 15s receive for JSON (was 120s)
  // Streaming uses a separate longer timeout set in audio_handler.dart
  static const int connectTimeout = 10000;
  static const int receiveTimeout = 15000;
}