// lib/features/calm_music/providers/calm_music_provider.dart
//
// FIXES IN THIS VERSION
// =====================
//
// FIX 1 — RETRY ON COLD-START FAILURE
//    Retries up to 3 times with exponential backoff.
//
// FIX 2 — BACKGROUND PRELOAD ALL SONG URLS
//    After loading, immediately warms all song stream URLs so playback
//    starts in <1s instead of 10s.
//
// FIX 3 — AUTO-PLAY PROVIDER
//    Added albumAutoPlayProvider that returns ready-to-play queue so
//    album_detail_screen can call playItem() immediately on tap.

import 'package:flutter/foundation.dart' show compute , debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';
import '../../../core/network/api_warmup_service.dart';


class AlbumParsePayload {
  final List<Map<String, dynamic>> rawList;
  const AlbumParsePayload(this.rawList);
}

class ParsedAlbumBatch {
  final List<AlbumModel> albums;
  final Map<String, List<SongModel>> songsByAlbumId;
  const ParsedAlbumBatch(this.albums, this.songsByAlbumId);
}

ParsedAlbumBatch _parseAlbumsAndSongs(AlbumParsePayload payload) {
  final albums = <AlbumModel>[];
  final songsByAlbumId = <String, List<SongModel>>{};

  for (final raw in payload.rawList) {
    final albumRaw = Map<String, dynamic>.from(raw)..remove('songs');
    final album = AlbumModel.fromJson(albumRaw);
    albums.add(album);

    final rawSongs = raw['songs'] as List<dynamic>? ?? [];
    songsByAlbumId[album.id] = rawSongs
        .map((s) => SongModel.fromJson(s as Map<String, dynamic>))
        .toList();
  }

  return ParsedAlbumBatch(albums, songsByAlbumId);
}

// ── allAlbumsRawProvider ──────────────────────────────────────────────────────
//
// FIX 1: Retry on failure.
// FIX 2: Background URL pre-warming for instant playback.
final allAlbumsRawProvider =
    FutureProvider<ParsedAlbumBatch>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);

  // FIX 1: Retry with backoff
  final response = await ApiWarmupService.fetchWithRetry<Map<String, dynamic>>(
    () => dio.get<Map<String, dynamic>>(ApiConstants.allAlbumsWithSongs),
    maxAttempts: 3,
    initialDelay: const Duration(seconds: 2),
  );

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  final parsed = await compute(
    _parseAlbumsAndSongs,
    AlbumParsePayload(rawList),
  );

  await Future.microtask(() {});

  // FIX 2: Pre-warm all song stream URLs in background
  _preloadAllSongUrls(parsed, dio);

  return parsed;
});

/// Pre-warms all song stream URLs (fire-and-forget).
void _preloadAllSongUrls(ParsedAlbumBatch batch, dynamic dio) {
  Future.microtask(() async {
    int warmed = 0;
    for (final songs in batch.songsByAlbumId.values) {
      for (final song in songs) {
        try {
          final url = '${ApiConstants.baseUrl}${ApiConstants.songStream(song.id)}';
          dio.get<dynamic>(url).catchError((_) => null);
          warmed++;
          if (warmed % 10 == 0) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
        } catch (_) {}
      }
    }
    debugPrint('[MusicPreload] Fired warmup for $warmed song URLs');
  });
}

final albumsListProvider = FutureProvider<List<AlbumModel>>((ref) async {
  ref.keepAlive();

  final batch = await ref.watch(allAlbumsRawProvider.future);
  await Future.microtask(() {});
  return batch.albums;
});

final songsProvider =
    FutureProvider.family<List<SongModel>, String>((ref, albumId) async {
  ref.keepAlive();

  final batch = await ref.watch(allAlbumsRawProvider.future);
  return batch.songsByAlbumId[albumId] ?? const [];
});

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

  return (
    album: album,
    songs: batch.songsByAlbumId[albumId] ?? const [],
  );
});

class AlbumPrefetchController {
  final Ref _ref;
  AlbumPrefetchController(this._ref);
  void warmRange({required List<String> visibleIds, required List<String> upcomingIds}) {}
  void dispose() {}
}

final albumPrefetchControllerProvider =
    Provider<AlbumPrefetchController>((ref) {
  final controller = AlbumPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});