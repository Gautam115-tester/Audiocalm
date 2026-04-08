// lib/features/calm_stories/providers/calm_stories_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// Series list provider
final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  final dio = ref.watch(dioClientProvider);
  try {
    final data = await dio.get<Map<String, dynamic>>(ApiConstants.series);
    final list = data['data'] as List? ?? [];
    return list.map((e) => SeriesModel.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
});

final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  final dio = ref.watch(dioClientProvider);
  try {
    final data = await dio.get<Map<String, dynamic>>(
        ApiConstants.seriesEpisodes(seriesId));
    final list = data['data'] as List? ?? [];
    return list.map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
});

final seriesDetailProvider =
    FutureProvider.family<SeriesModel?, String>((ref, id) async {
  final dio = ref.watch(dioClientProvider);
  try {
    final data = await dio.get<Map<String, dynamic>>(ApiConstants.seriesById(id));
    return SeriesModel.fromJson(data['data'] as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
});
