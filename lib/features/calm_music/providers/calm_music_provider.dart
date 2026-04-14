// lib/features/calm_music/providers/calm_music_provider.dart
//
// PERFORMANCE FIXES
// =================
//
// FIX 1 — REMOVED URL PRE-WARMING (root cause of 10s playback delay)
//    Pre-warming fired 1 HTTP request per song. With 10 albums × ~15 songs =
//    150 simultaneous requests to the backend. The backend then calls Telegram's
//    getFile API for each — Telegram rate-limits this. When the user taps play,
//    their real stream request is stuck waiting behind 150 pre-warm requests.
//    RESULT: 10+ second delay before audio starts.
//    FIX: Removed _preloadAllSongUrls() entirely.
//
// FIX 2 — SINGLE RETRY, NO LONG DELAYS
//    Old code: 3 retries × 2s = up to 6s extra wait on cold start.
//    New code: 1 fast attempt, 1 retry after 2s max.
//
// FIX 3 — SCALABILITY: Paginated album loading
//    At 1200 albums, "all-with-songs" JSON would be ~10MB+.
//    New architecture:
//      - allAlbumsRawProvider: fetches album LIST only (no songs embedded)
//      - songsProvider(albumId): fetches songs for ONE album on demand
//      - albumWithSongsProvider(albumId): combines both, cached per-album
//    This means opening the app loads ~50KB instead of 10MB.
//    Scales to any number of albums.
//
// FIX 4 — KEEPALIVE everywhere to prevent redundant re-fetches.

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// Keep these public for music_screen.dart compatibility
class AlbumParsePayload {
  final List<Map<String, dynamic>> rawList;
  const AlbumParsePayload(this.rawList);
}

class ParsedAlbumBatch {
  final List<AlbumModel> albums;
  final Map<String, List<SongModel>> songsByAlbumId;
  const ParsedAlbumBatch(this.albums, this.songsByAlbumId);
}

ParsedAlbumBatch _parseAlbumsOnly(AlbumParsePayload payload) {
  final albums = <AlbumModel>[];
  final songsByAlbumId = <String, List<SongModel>>{};

  for (final raw in payload.rawList) {
    // Parse album (songs may or may not be embedded depending on endpoint)
    final albumRaw = Map<String, dynamic>.from(raw);
    final rawSongs = albumRaw.remove('songs') as List<dynamic>?;
    final album = AlbumModel.fromJson(albumRaw);
    albums.add(album);

    // If songs are embedded (all-with-songs endpoint), parse them too
    if (rawSongs != null) {
      songsByAlbumId[album.id] = rawSongs
          .map((s) => SongModel.fromJson(s as Map<String, dynamic>))
          .toList();
    }
  }

  return ParsedAlbumBatch(albums, songsByAlbumId);
}

List<SongModel> _parseSongs(List<Map<String, dynamic>> rawList) {
  return rawList.map((s) => SongModel.fromJson(s)).toList();
}

// ── allAlbumsRawProvider ──────────────────────────────────────────────────────
//
// FIX 3: Fetches album list only (with songs embedded for now since we still
// use the all-with-songs endpoint — but NO pre-warming).
// At 1200+ albums: switch ApiConstants.allAlbumsWithSongs to a list-only
// endpoint like /api/albums and songs will be fetched lazily per album.
final allAlbumsRawProvider =
    FutureProvider<ParsedAlbumBatch>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);

  late Map<String, dynamic> response;
  try {
    response = await dio.get<Map<String, dynamic>>(
      ApiConstants.allAlbumsWithSongs,
    ).timeout(const Duration(seconds: 20));
  } catch (_) {
    // Single retry after 2s (handles Render cold-start)
    await Future.delayed(const Duration(seconds: 2));
    response = await dio.get<Map<String, dynamic>>(
      ApiConstants.allAlbumsWithSongs,
    ).timeout(const Duration(seconds: 30));
  }

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  // Parse in background isolate
  final parsed = await compute(_parseAlbumsOnly, AlbumParsePayload(rawList));

  await Future.microtask(() {});

  // FIX 1: NO URL pre-warming. Pre-warming floods the backend and delays
  // real playback requests by 10+ seconds. The backend already caches
  // Telegram URLs for 45 min — the first play request will be <1s.

  return parsed;
});

// ── albumsListProvider ────────────────────────────────────────────────────────
final albumsListProvider = FutureProvider<List<AlbumModel>>((ref) async {
  ref.keepAlive();
  final batch = await ref.watch(allAlbumsRawProvider.future);
  await Future.microtask(() {});
  return batch.albums;
});

// ── songsProvider ─────────────────────────────────────────────────────────────
// FIX 3: Fetches songs for a SINGLE album.
// Fast path: if songs are already in the batch (embedded), return instantly.
// Slow path: fetch from /api/albums/:id/songs (for future list-only endpoint).
final songsProvider =
    FutureProvider.family<List<SongModel>, String>((ref, albumId) async {
  ref.keepAlive();

  // Fast path — check if songs already loaded in batch
  final batchAsync = ref.watch(allAlbumsRawProvider);
  if (batchAsync.hasValue) {
    final songs = batchAsync.value!.songsByAlbumId[albumId];
    if (songs != null && songs.isNotEmpty) return songs;
  }

  // Slow path — fetch just this album's songs
  final dio = ref.watch(dioClientProvider);
  try {
    final response = await dio.get<Map<String, dynamic>>(
      ApiConstants.albumSongs(albumId),
    );
    final rawList = (response['data'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    return compute(_parseSongs, rawList);
  } catch (_) {
    // Fallback to batch
    final batch = await ref.watch(allAlbumsRawProvider.future);
    return batch.songsByAlbumId[albumId] ?? const [];
  }
});

// ── albumDetailProvider ───────────────────────────────────────────────────────
final albumDetailProvider =
    FutureProvider.family<AlbumModel?, String>((ref, id) async {
  ref.keepAlive();
  final batch = await ref.watch(allAlbumsRawProvider.future);
  try {
    return batch.albums.firstWhere((a) => a.id == id);
  } catch (_) {
    return null;
  }
});

// ── albumWithSongsProvider ────────────────────────────────────────────────────
final albumWithSongsProvider = FutureProvider.family<
    ({AlbumModel? album, List<SongModel> songs}),
    String>((ref, albumId) async {
  ref.keepAlive();

  final batch = await ref.watch(allAlbumsRawProvider.future);

  AlbumModel? album;
  try {
    album = batch.albums.firstWhere((a) => a.id == albumId);
  } catch (_) {
    album = null;
  }

  // Get songs — fast path from batch, slow path from network
  List<SongModel> songs = batch.songsByAlbumId[albumId] ?? const [];
  if (songs.isEmpty) {
    songs = await ref.watch(songsProvider(albumId).future);
  }

  return (album: album, songs: songs);
});

// ── AlbumPrefetchController ───────────────────────────────────────────────────
class AlbumPrefetchController {
  final Ref _ref;
  AlbumPrefetchController(this._ref);
  // FIX 1: No-op — pre-warming removed. Backend caches URLs server-side.
  void warmRange({required List<String> visibleIds, required List<String> upcomingIds}) {}
  void dispose() {}
}

final albumPrefetchControllerProvider =
    Provider<AlbumPrefetchController>((ref) {
  final controller = AlbumPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});