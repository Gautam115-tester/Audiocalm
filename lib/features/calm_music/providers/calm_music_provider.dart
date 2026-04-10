// lib/features/calm_music/providers/calm_music_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// PERF FIX: keepAlive = true — data is cached in memory across tab switches.
// Without this, switching Home→Music→Home→Music refetches every time.
final albumsListProvider = FutureProvider<List<AlbumModel>>((ref) async {
  // Keep this data alive so it's never refetched during the session
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

// PERF FIX: Songs are cached per albumId — navigating back and forth is instant
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

// PERF FIX: albumDetailProvider + songsProvider are fetched in parallel
// via the new albumWithSongsProvider — one navigation = 2 concurrent requests
// instead of 2 sequential requests.
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

// PERF FIX: Single provider that fires BOTH requests in parallel.
// Album detail screen watches this instead of two separate providers.
final albumWithSongsProvider = FutureProvider.family<
    ({AlbumModel? album, List<SongModel> songs}), String>((ref, albumId) async {
  ref.keepAlive();

  // Fire both requests at the exact same time
  final results = await Future.wait([
    ref.watch(albumDetailProvider(albumId).future),
    ref.watch(songsProvider(albumId).future),
  ]);

  return (
    album: results[0] as AlbumModel?,
    songs: results[1] as List<SongModel>,
  );
});