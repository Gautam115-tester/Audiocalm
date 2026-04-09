// lib/features/calm_stories/providers/calm_stories_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  final dio = ref.watch(dioClientProvider);
  try {
    // Backend returns { success: true, data: [...] }
    final response = await dio.get<Map<String, dynamic>>(ApiConstants.series);
    final data = response['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => SeriesModel.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (e) {
    return [];
  }
});

final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  final dio = ref.watch(dioClientProvider);
  try {
    // Backend returns { success: true, data: [...] }
    final response = await dio.get<Map<String, dynamic>>(
      ApiConstants.seriesEpisodes(seriesId),
    );
    final data = response['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (e) {
    return [];
  }
});

final seriesDetailProvider =
    FutureProvider.family<SeriesModel?, String>((ref, id) async {
  final dio = ref.watch(dioClientProvider);
  try {
    // Backend returns { success: true, data: { ... } }
    final response = await dio.get<Map<String, dynamic>>(ApiConstants.seriesById(id));
    final data = response['data'] as Map<String, dynamic>?;
    if (data == null) return null;
    return SeriesModel.fromJson(data);
  } catch (e) {
    return null;
  }
});