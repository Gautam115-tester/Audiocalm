// lib/features/calm_music/providers/calm_music_provider.dart
//
// ROOT CAUSE FIX:
// albumWithSongsProvider calls BOTH albumDetailProvider + songsProvider.
// Previous prefetch only warmed songsProvider → album detail still fetched
// on tap → visible 1-2s delay.
//
// Now the controller warms BOTH in parallel for every visible/upcoming album.
// When user taps → albumWithSongsProvider reads from cache → instant open.

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// ── Albums list ──────────────────────────────────────────────────────────────

final albumsListProvider = FutureProvider<List<AlbumModel>>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  try {
    final response = await dio.get<Map<String, dynamic>>(ApiConstants.albums);
    final data = response['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => AlbumModel.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (e) {
    return [];
  }
});

// ── Songs (per album) ────────────────────────────────────────────────────────

final songsProvider =
    FutureProvider.family<List<SongModel>, String>((ref, albumId) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  try {
    final response =
        await dio.get<Map<String, dynamic>>(ApiConstants.albumSongs(albumId));
    final data = response['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => SongModel.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (e) {
    return [];
  }
});

// ── Album detail ─────────────────────────────────────────────────────────────

final albumDetailProvider =
    FutureProvider.family<AlbumModel?, String>((ref, id) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  try {
    final response =
        await dio.get<Map<String, dynamic>>(ApiConstants.albumById(id));
    final data = response['data'] as Map<String, dynamic>?;
    if (data == null) return null;
    return AlbumModel.fromJson(data);
  } catch (e) {
    return null;
  }
});

// ── Combined (parallel fetch) ─────────────────────────────────────────────────
// Both sub-providers are keepAlive + prefetched, so this resolves from
// cache instantly after the background warm-up completes.

final albumWithSongsProvider = FutureProvider.family<
    ({AlbumModel? album, List<SongModel> songs}), String>((ref, albumId) async {
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

// ── Smart Prefetch Controller ─────────────────────────────────────────────────
//
// FIX: Now prefetches BOTH albumDetailProvider AND songsProvider per album.
// This means albumWithSongsProvider (which needs both) resolves from cache
// with zero network latency when the user taps.
//
// Behaviour:
//   • Visible items  → warm immediately, both requests in parallel
//   • Upcoming items → warm after 300ms debounce (cancelled on fast scroll)
//   • Already cached → O(1) Set check, zero network cost
//   • 80ms gap between background items → server never flooded

class AlbumPrefetchController {
  final Ref _ref;

  // Tracks albumIds where BOTH detail + songs are already fetched/in-flight
  final Set<String> _cached = {};

  Timer? _debounce;
  bool _cancelled = false;

  AlbumPrefetchController(this._ref);

  void warmRange({
    required List<String> visibleIds,
    required List<String> upcomingIds,
  }) {
    // HIGH PRIORITY: visible items — fire immediately
    for (final id in visibleIds) {
      _prefetchIfNeeded(id);
    }

    // LOW PRIORITY: upcoming items — debounced
    _debounce?.cancel();
    _cancelled = true;

    _debounce = Timer(const Duration(milliseconds: 300), () {
      _cancelled = false;
      _prefetchUpcoming(upcomingIds);
    });
  }

  Future<void> _prefetchUpcoming(List<String> ids) async {
    for (final id in ids) {
      if (_cancelled) return;
      await _prefetchIfNeeded(id);
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> _prefetchIfNeeded(String albumId) async {
    if (_cached.contains(albumId)) return; // already warm — free no-op
    _cached.add(albumId);
    try {
      // FIX: Warm BOTH providers in parallel — this is what albumWithSongsProvider
      // needs, so tapping it will find everything already in cache.
      await Future.wait([
        _ref.read(albumDetailProvider(albumId).future),
        _ref.read(songsProvider(albumId).future),
      ]);
    } catch (_) {
      _cached.remove(albumId); // allow retry on next scroll
    }
  }

  void dispose() {
    _debounce?.cancel();
    _cancelled = true;
  }
}

final albumPrefetchControllerProvider =
    Provider<AlbumPrefetchController>((ref) {
  final controller = AlbumPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});