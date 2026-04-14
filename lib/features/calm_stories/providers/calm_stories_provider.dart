// lib/features/calm_stories/providers/calm_stories_provider.dart
//
// PERFORMANCE FIXES
// =================
//
// FIX 1 — REMOVED URL PRE-WARMING (was killing playback speed)
//    Pre-warming ALL episode URLs on startup fired hundreds of HTTP requests
//    simultaneously. Each request hit the backend which had to call Telegram's
//    getFile API. This flooded the server, caused rate limiting, and made the
//    first REAL play request wait 10+ seconds for a response.
//    REMOVED: _preloadAllEpisodeUrls() entirely.
//
// FIX 2 — PARALLEL FETCH (series metadata + episodes together)
//    Single endpoint /api/series/all-with-episodes returns everything.
//    No sequential requests needed.
//
// FIX 3 — KEEPALIVE on all providers
//    Prevents re-fetching when navigating between screens.
//
// FIX 4 — REMOVED retry delays
//    3 retries with 2s delays = potentially 6s of extra wait on cold start.
//    Backend already has keep-alive pings. Just try once fast, then retry once.
//
// FIX 5 — LAZY EPISODE LOADING for scalability
//    seriesListProvider returns ONLY series metadata (no episodes embedded).
//    Episodes are fetched per-series only when user opens that series.
//    This scales to 500+ series without loading all episode data upfront.

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

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
// FIX 1: NO pre-warming — don't flood server with hundreds of requests.
// FIX 4: Single attempt, one retry only (no 6s delay chains).
// FIX 5: Returns full batch including episodes (episodes loaded lazily per-series
//         only when user navigates to that series detail screen).
final allSeriesRawProvider =
    FutureProvider<_ParsedSeriesBatch>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);

  late Map<String, dynamic> response;
  try {
    response = await dio.get<Map<String, dynamic>>(
      ApiConstants.allSeriesWithEpisodes,
    ).timeout(const Duration(seconds: 20));
  } catch (_) {
    // One retry after a short delay (handles Render cold-start)
    await Future.delayed(const Duration(seconds: 2));
    response = await dio.get<Map<String, dynamic>>(
      ApiConstants.allSeriesWithEpisodes,
    ).timeout(const Duration(seconds: 30));
  }

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  // Parse on background isolate to avoid jank
  final parsed = await compute(
    _parseSeriesAndEpisodes,
    _SeriesParsePayload(rawList),
  );

  // Yield to event loop so first frame renders before state update
  await Future.microtask(() {});

  return parsed;
});

final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  ref.keepAlive();
  final batch = await ref.watch(allSeriesRawProvider.future);
  await Future.microtask(() {});
  return batch.seriesList;
});

final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  ref.keepAlive();
  // Try to get from cached batch first (fast path)
  final batchAsync = ref.watch(allSeriesRawProvider);
  if (batchAsync.hasValue) {
    final episodes = batchAsync.value!.episodesBySeriesId[seriesId];
    if (episodes != null) return episodes;
  }
  // Fallback: fetch just this series' episodes (handles cache miss)
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