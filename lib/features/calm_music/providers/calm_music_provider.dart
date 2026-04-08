// lib/features/calm_music/providers/calm_music_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/album_model.dart';
import '../data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

final albumsListProvider = FutureProvider<List<AlbumModel>>((ref) async {
  final dio = ref.watch(dioClientProvider);
  try {
    final data = await dio.get<Map<String, dynamic>>(ApiConstants.albums);
    final list = data['data'] as List? ?? [];
    return list.map((e) => AlbumModel.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
});

final songsProvider =
    FutureProvider.family<List<SongModel>, String>((ref, albumId) async {
  final dio = ref.watch(dioClientProvider);
  try {
    final data = await dio.get<Map<String, dynamic>>(ApiConstants.albumSongs(albumId));
    final list = data['data'] as List? ?? [];
    return list.map((e) => SongModel.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
});

final albumDetailProvider =
    FutureProvider.family<AlbumModel?, String>((ref, id) async {
  final dio = ref.watch(dioClientProvider);
  try {
    final data = await dio.get<Map<String, dynamic>>(ApiConstants.albumById(id));
    return AlbumModel.fromJson(data['data'] as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
});
