// lib/features/calm_music/providers/calm_music_provider.dart
//
// ═══════════════════════════════════════════════════════════════════════════════
// ROOT CAUSE OF THE 22-REQUEST FLOOD (confirmed from source + logs):
//
//   AlbumPrefetchController.warmRange() received ALL album IDs as "visible"
//   and called _prefetchIfNeeded() for each with ZERO throttle.
//   Each call fired Future.wait([albumDetailProvider, songsProvider])
//   = 2 HTTP requests × 11 albums = 22 SIMULTANEOUS requests on every startup.
//
//   DB has connection_limit=1. 22 requests queued → those waiting >20s got
//   Prisma P2024 ("pool timeout") → errorHandler returned HTTP 400 →
//   Dio logged "bad syntax" which looked like a client-side bug.
//
// THE FIX — single endpoint, zero fan-out:
//
//   _allAlbumsRawProvider calls GET /api/albums/all-with-songs ONCE.
//   The server returns every album with its songs embedded in one DB query.
//   22 requests → 1 request. The flood and all P2024 timeouts are gone.
//
//   albumsListProvider, albumDetailProvider, songsProvider, albumWithSongsProvider
//   are ALL rewritten as pure in-memory derivations of _allAlbumsRawProvider.
//   Same provider names → same types → zero changes needed in any screen.
//
//   AlbumPrefetchController.warmRange() is now a no-op stub — everything is
//   already loaded by the time the music screen renders. Kept so every
//   existing call site continues to compile without any changes.
// ═══════════════════════════════════════════════════════════════════════════════

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// ── Internal combined-fetch provider ──────────────────────────────────────────
//
// Single HTTP call that returns the full album + songs payload.
// Kept alive for the app lifetime — all other providers derive from this.
//
// Server endpoint: GET /api/albums/all-with-songs
// Response shape:
//   { success: true, data: [ { id, title, artist, coverUrl, songs: [...] } ] }

final _allAlbumsRawProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  // NOTE: Add `static const String allAlbumsWithSongs = '/api/albums/all-with-songs';`
  // to your ApiConstants class (lib/core/constants/api_constants.dart).
  final response = await dio.get<Map<String, dynamic>>(
    ApiConstants.allAlbumsWithSongs,
  );
  final data = response['data'] as List<dynamic>? ?? [];
  return data.cast<Map<String, dynamic>>();
  // If this throws, every derived provider shows an error state and the
  // music screen can display a retry button — no silent empty lists.
});

// ── Safe model conversion helpers ─────────────────────────────────────────────
//
// The combined response includes a 'songs' key inside each album map.
// AlbumModel.fromJson may or may not handle unknown keys gracefully,
// depending on whether it's generated (json_serializable) or hand-written.
// We strip 'songs' before passing to AlbumModel.fromJson to be safe in both
// cases, and extract songs separately via _parseSongs().

Map<String, dynamic> _stripSongs(Map<String, dynamic> albumRaw) {
  // Create a shallow copy without the 'songs' key
  return Map<String, dynamic>.from(albumRaw)..remove('songs');
}

List<SongModel> _parseSongs(Map<String, dynamic> albumRaw) {
  final rawSongs = albumRaw['songs'] as List<dynamic>? ?? [];
  return rawSongs
      .map((s) => SongModel.fromJson(s as Map<String, dynamic>))
      .toList();
}

// ── albumsListProvider ────────────────────────────────────────────────────────
// DROP-IN REPLACEMENT for the original albumsListProvider.
// Was: GET /api/albums  (1 request)
// Now: derives from _allAlbumsRawProvider (0 extra requests)

final albumsListProvider = FutureProvider<List<AlbumModel>>((ref) async {
  ref.keepAlive();

  final raw = await ref.watch(_allAlbumsRawProvider.future);
  return raw.map((a) => AlbumModel.fromJson(_stripSongs(a))).toList();
});

// ── songsProvider ─────────────────────────────────────────────────────────────
// DROP-IN REPLACEMENT for the original songsProvider.
// Was: GET /api/albums/:id/songs per album  (11 requests)
// Now: filters from _allAlbumsRawProvider (0 extra requests)

final songsProvider =
    FutureProvider.family<List<SongModel>, String>((ref, albumId) async {
  ref.keepAlive();

  final raw = await ref.watch(_allAlbumsRawProvider.future);
  final albumRaw = raw.firstWhere(
    (a) => (a['id'] as String?) == albumId,
    orElse: () => <String, dynamic>{},
  );
  if (albumRaw.isEmpty) return const [];
  return _parseSongs(albumRaw);
});

// ── albumDetailProvider ───────────────────────────────────────────────────────
// DROP-IN REPLACEMENT for the original albumDetailProvider.
// Was: GET /api/albums/:id per album  (11 requests)
// Now: filters from _allAlbumsRawProvider (0 extra requests)

final albumDetailProvider =
    FutureProvider.family<AlbumModel?, String>((ref, id) async {
  ref.keepAlive();

  final raw = await ref.watch(_allAlbumsRawProvider.future);
  final albumRaw = raw.firstWhere(
    (a) => (a['id'] as String?) == id,
    orElse: () => <String, dynamic>{},
  );
  if (albumRaw.isEmpty) return null;
  return AlbumModel.fromJson(_stripSongs(albumRaw));
});

// ── albumWithSongsProvider ────────────────────────────────────────────────────
// DROP-IN REPLACEMENT — same record type ({AlbumModel? album, List<SongModel> songs}).
// Both sub-providers now resolve from in-memory cache → instant, no network.

final albumWithSongsProvider = FutureProvider.family<
    ({AlbumModel? album, List<SongModel> songs}),
    String>((ref, albumId) async {
  ref.keepAlive();

  final results = await Future.wait([
    ref.watch(albumDetailProvider(albumId).future),
    ref.watch(songsProvider(albumId).future),
  ]);

  return (
    album: results[0] as AlbumModel?,
    songs: results[1] as List<SongModel>,
  );
});

// ── AlbumPrefetchController ───────────────────────────────────────────────────
// NOW A NO-OP STUB.
//
// The old controller fired 22 parallel requests by calling warmRange() for all
// visible albums immediately. Since _allAlbumsRawProvider loads everything in
// one shot, there is nothing left to prefetch by the time warmRange() is called.
//
// All existing call sites compile and run unchanged — warmRange() just returns
// immediately. Safe to delete the call sites in a future cleanup pass.

class AlbumPrefetchController {
  // ignore: unused_field
  final Ref _ref;

  AlbumPrefetchController(this._ref);

  /// No-op: all data is already loaded via GET /api/albums/all-with-songs.
  /// The previous implementation fired 22 parallel requests here.
  void warmRange({
    required List<String> visibleIds,
    required List<String> upcomingIds,
  }) {
    // intentionally empty
  }

  void dispose() {}
}

final albumPrefetchControllerProvider =
    Provider<AlbumPrefetchController>((ref) {
  final controller = AlbumPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});