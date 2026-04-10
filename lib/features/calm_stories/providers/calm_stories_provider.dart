// lib/features/calm_stories/providers/calm_stories_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// PERF FIX: keepAlive — series list is fetched once per session, never again
final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  try {
    final response = await dio.get<Map<String, dynamic>>(ApiConstants.series);
    final data = response['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => SeriesModel.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (e) {
    return [];
  }
});

// PERF FIX: Episodes cached per seriesId
final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  try {
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
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);
  try {
    final response =
        await dio.get<Map<String, dynamic>>(ApiConstants.seriesById(id));
    final data = response['data'] as Map<String, dynamic>?;
    if (data == null) return null;
    return SeriesModel.fromJson(data);
  } catch (e) {
    return null;
  }
});

// PERF FIX: Parallel fetch — series detail + episodes in one shot
final seriesWithEpisodesProvider = FutureProvider.family<
    ({SeriesModel? series, List<EpisodeModel> episodes}),
    String>((ref, seriesId) async {
  ref.keepAlive();

  final results = await Future.wait([
    ref.watch(seriesDetailProvider(seriesId).future),
    ref.watch(episodesProvider(seriesId).future),
  ]);

  return (
    series: results[0] as SeriesModel?,
    episodes: results[1] as List<EpisodeModel>,
  );
});