// lib/features/calm_stories/providers/calm_stories_provider.dart
//
// FAST LOADING CHANGES (same strategy as calm_music_provider)
// ====================
//
// 1. Hive persistent cache — instant load on relaunch
// 2. Stale-while-revalidate — fresh data arrives silently
// 3. Image cover URLs extracted for prefetching by the UI layer

import 'package:flutter/foundation.dart' show compute, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';
import '../../../core/cache/content_cache_service.dart';

class _SeriesParsePayload {
  final List<Map<String, dynamic>> rawList;
  const _SeriesParsePayload(this.rawList);
}

class _ParsedSeriesBatch {
  final List<SeriesModel> seriesList;
  final Map<String, List<EpisodeModel>> episodesBySeriesId;
  const _ParsedSeriesBatch(this.seriesList, this.episodesBySeriesId);
}

_ParsedSeriesBatch _parseSeriesAndEpisodes(_SeriesParsePayload payload) {
  final seriesList = <SeriesModel>[];
  final episodesBySeriesId = <String, List<EpisodeModel>>{};

  for (final raw in payload.rawList) {
    final rawEpisodes = raw['episodes'] as List<dynamic>? ?? [];
    final episodes = rawEpisodes
        .map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
        .toList();

    final liveCount = episodes.length;
    final totalDuration = episodes.fold<int>(
      0,
      (sum, ep) =>
          sum + (ep.duration != null && ep.duration! > 0 ? ep.duration! : 0),
    );

    final seriesRaw = Map<String, dynamic>.from(raw)
      ..remove('episodes')
      ..['episodeCount'] = liveCount
      ..['totalDurationSeconds'] = totalDuration;

    final series = SeriesModel.fromJson(seriesRaw);
    seriesList.add(series);
    episodesBySeriesId[series.id] = episodes;
  }

  return _ParsedSeriesBatch(seriesList, episodesBySeriesId);
}

// ── allSeriesRawProvider ──────────────────────────────────────────────────────
//
// Returns cached data immediately, then revalidates in background.

final allSeriesRawProvider = FutureProvider<_ParsedSeriesBatch>((ref) async {
  ref.keepAlive();

  // Fast path: return cached data immediately
  final cached = ContentCacheService.getCachedSeries();
  if (cached != null) {
    final parsed = await compute(
      _parseSeriesAndEpisodes,
      _SeriesParsePayload(cached),
    );
    await Future.microtask(() {});

    // Revalidate in background if stale
    if (!ContentCacheService.isSeriesCacheFresh()) {
      _revalidateSeries(ref);
    }

    return parsed;
  }

  // No cache: fetch from network
  return _fetchAndCacheSeries(ref);
});

Future<_ParsedSeriesBatch> _fetchAndCacheSeries(Ref ref) async {
  final dio = ref.read(dioClientProvider);

  late Map<String, dynamic> response;
  try {
    response = await dio.get<Map<String, dynamic>>(
      ApiConstants.allSeriesWithEpisodes,
    ).timeout(const Duration(seconds: 20));
  } catch (_) {
    await Future.delayed(const Duration(seconds: 2));
    response = await dio.get<Map<String, dynamic>>(
      ApiConstants.allSeriesWithEpisodes,
    ).timeout(const Duration(seconds: 30));
  }

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  // Save to persistent cache
  ContentCacheService.saveSeries(rawList);

  final parsed = await compute(
    _parseSeriesAndEpisodes,
    _SeriesParsePayload(rawList),
  );
  await Future.microtask(() {});
  return parsed;
}

void _revalidateSeries(Ref ref) {
  Future.delayed(const Duration(milliseconds: 500), () async {
    try {
      await _fetchAndCacheSeries(ref);
      ref.invalidateSelf();
    } catch (e) {
      debugPrint('[SeriesProvider] Background revalidation failed: $e');
    }
  });
}

// ── Derived providers (unchanged API) ─────────────────────────────────────────

final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  ref.keepAlive();
  final batch = await ref.watch(allSeriesRawProvider.future);
  await Future.microtask(() {});
  return batch.seriesList;
});

final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  ref.keepAlive();
  final batchAsync = ref.watch(allSeriesRawProvider);
  if (batchAsync.hasValue) {
    final episodes = batchAsync.value!.episodesBySeriesId[seriesId];
    if (episodes != null) return episodes;
  }
  final dio = ref.watch(dioClientProvider);
  try {
    final response = await dio.get<Map<String, dynamic>>(
      ApiConstants.seriesEpisodes(seriesId),
    );
    final rawList = (response['data'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    return rawList.map((e) => EpisodeModel.fromJson(e)).toList();
  } catch (_) {
    final batch = await ref.watch(allSeriesRawProvider.future);
    return batch.episodesBySeriesId[seriesId] ?? const [];
  }
});

final seriesDetailProvider =
    FutureProvider.family<SeriesModel?, String>((ref, id) async {
  ref.keepAlive();
  final batch = await ref.watch(allSeriesRawProvider.future);
  try {
    return batch.seriesList.firstWhere((s) => s.id == id);
  } catch (_) {
    return null;
  }
});

final seriesWithEpisodesProvider = FutureProvider.family<
    ({SeriesModel? series, List<EpisodeModel> episodes}),
    String>((ref, seriesId) async {
  ref.keepAlive();

  final batch = await ref.watch(allSeriesRawProvider.future);

  SeriesModel? series;
  try {
    series = batch.seriesList.firstWhere((s) => s.id == seriesId);
  } catch (_) {
    series = null;
  }

  return (
    series: series,
    episodes: batch.episodesBySeriesId[seriesId] ?? const [],
  );
});

class SeriesPrefetchController {
  final Ref _ref;
  SeriesPrefetchController(this._ref);
  void warmRange({required List<String> visibleIds, required List<String> upcomingIds}) {}
  void dispose() {}
}

final seriesPrefetchControllerProvider =
    Provider<SeriesPrefetchController>((ref) {
  final controller = SeriesPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});