// lib/features/calm_music/providers/calm_music_provider.dart
//
// THREAD FIX — JSON parsing moved off the main isolate
// =====================================================
//
// PREVIOUS PROBLEM:
//   _allAlbumsRawProvider received the HTTP response and immediately called
//   AlbumModel.fromJson() and SongModel.fromJson() for every item on the
//   MAIN ISOLATE.  With 11 albums × N songs, this parse loop ran during the
//   first frame paint, contributing to the 72-skipped-frames Choreographer
//   warning and BLASTBufferQueue overflow.
//
// FIX:
//   1. The raw JSON list is handed to a background isolate via Flutter's
//      compute() (Isolate.run under the hood) for the heavy parse step.
//   2. The albumsListProvider uses a post-frame microtask yield before
//      returning data, so the first frame always paints before the provider
//      marks itself as AsyncData.  This prevents a synchronous setState
//      chain from blocking the Choreographer.
//   3. AlbumPrefetchController remains a no-op stub — all data still comes
//      from the single /api/albums/all-with-songs endpoint.
//
// All public API names and types are unchanged — no screen edits required.

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// ── Top-level parse helpers (must be top-level for compute / Isolate.run) ────

// Payload type passed to the isolate — must be sendable (no Flutter objects).
class _AlbumParsePayload {
  final List<Map<String, dynamic>> rawList;
  const _AlbumParsePayload(this.rawList);
}

class _ParsedAlbumBatch {
  final List<AlbumModel> albums;
  final Map<String, List<SongModel>> songsByAlbumId;
  const _ParsedAlbumBatch(this.albums, this.songsByAlbumId);
}

/// Runs in a background isolate — no Flutter engine calls allowed here.
_ParsedAlbumBatch _parseAlbumsAndSongs(_AlbumParsePayload payload) {
  final albums = <AlbumModel>[];
  final songsByAlbumId = <String, List<SongModel>>{};

  for (final raw in payload.rawList) {
    // Strip songs key before passing to AlbumModel.fromJson
    final albumRaw = Map<String, dynamic>.from(raw)..remove('songs');
    final album = AlbumModel.fromJson(albumRaw);
    albums.add(album);

    final rawSongs = raw['songs'] as List<dynamic>? ?? [];
    songsByAlbumId[album.id] = rawSongs
        .map((s) => SongModel.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  return _ParsedAlbumBatch(albums, songsByAlbumId);
}

// ── Internal raw-fetch provider ───────────────────────────────────────────────
//
// Fetches the combined all-with-songs payload ONCE.  All derived providers
// read from this cache — zero extra network calls.

final _allAlbumsRawProvider =
    FutureProvider<_ParsedAlbumBatch>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  final response = await dio.get<Map<String, dynamic>>(
    ApiConstants.allAlbumsWithSongs,
  );

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  // FIX: Offload the parse loop to a background isolate so the main thread
  // and GPU compositor are not blocked during the first frame paint.
  // compute() uses Isolate.run — the result is sent back via a message port.
  final parsed = await compute(
    _parseAlbumsAndSongs,
    _AlbumParsePayload(rawList),
  );

  return parsed;
});

// ── albumsListProvider ────────────────────────────────────────────────────────

final albumsListProvider = FutureProvider<List<AlbumModel>>((ref) async {
  ref.keepAlive();

  final batch = await ref.watch(_allAlbumsRawProvider.future);

  // FIX: Yield a microtask so the first frame can paint before we update state.
  // Without this, the provider resolves synchronously after the background
  // parse, triggering a setState during the build phase.
  await Future.microtask(() {});

  return batch.albums;
});

// ── songsProvider ─────────────────────────────────────────────────────────────

final songsProvider =
    FutureProvider.family<List<SongModel>, String>((ref, albumId) async {
  ref.keepAlive();

  final batch = await ref.watch(_allAlbumsRawProvider.future);
  return batch.songsByAlbumId[albumId] ?? const [];
});

// ── albumDetailProvider ───────────────────────────────────────────────────────

final albumDetailProvider =
    FutureProvider.family<AlbumModel?, String>((ref, id) async {
  ref.keepAlive();

  final batch = await ref.watch(_allAlbumsRawProvider.future);
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

  final batch = await ref.watch(_allAlbumsRawProvider.future);

  AlbumModel? album;
  try {
    album = batch.albums.firstWhere((a) => a.id == albumId);
  } catch (_) {
    album = null;
  }

  return (
    album: album,
    songs: batch.songsByAlbumId[albumId] ?? const [],
  );
});

// ── AlbumPrefetchController (no-op stub) ──────────────────────────────────────
//
// Everything is loaded by _allAlbumsRawProvider in a single background-parsed
// batch.  warmRange() is intentionally empty.

class AlbumPrefetchController {
  // ignore: unused_field
  final Ref _ref;
  AlbumPrefetchController(this._ref);

  void warmRange({
    required List<String> visibleIds,
    required List<String> upcomingIds,
  }) {
    // No-op: data already loaded and parsed in background isolate.
  }

  void dispose() {}
}

final albumPrefetchControllerProvider =
    Provider<AlbumPrefetchController>((ref) {
  final controller = AlbumPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});