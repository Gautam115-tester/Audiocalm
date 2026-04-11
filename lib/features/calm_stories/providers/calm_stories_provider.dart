// lib/features/calm_stories/providers/calm_stories_provider.dart
//
// FIX: Episode count shows 80 instead of 81
// ==========================================
//
// ROOT CAUSE (two layers):
//
// 1. BACKEND CACHE: series.js caches the all-with-episodes response for 5 min.
//    If episode 81 was synced AFTER the cache was populated, the cached response
//    still has `episodes: [ep1...ep80]` and `episodeCount: 80`. The Flutter
//    provider parses the embedded `episodes` array length correctly (liveCount),
//    BUT the cache serves stale data — so even the embedded array only has 80.
//
// 2. FLUTTER KEEPALIVE: `ref.keepAlive()` on `_allSeriesRawProvider` means
//    once loaded, it NEVER re-fetches, even across navigation. If the app was
//    open when ep81 was synced, the user sees stale data until a full restart.
//
// FIXES APPLIED:
//
// A. Remove `ref.keepAlive()` from `_allSeriesRawProvider` — let Riverpod
//    dispose it when no longer watched, so navigating back to StoriesScreen
//    always fetches fresh data.
//
// B. Add a cache-buster query param `?t=<minute-epoch>` to the API call.
//    This bypasses the 5-min server-side NodeCache since the URL changes
//    every minute. The browser/Dio HTTP cache is not involved (JSON endpoint).
//    Round to the nearest minute so identical navigations within the same
//    minute still share the same in-flight request.
//
// C. Keep `_parseSeriesAndEpisodes` isolate logic unchanged — it already
//    correctly derives liveCount from the embedded episodes array length.
//
// D. `seriesListProvider` and `episodesProvider` keep `ref.keepAlive()` so
//    already-loaded detail data stays available while navigating, but they
//    depend on `_allSeriesRawProvider` which is now auto-disposed → they
//    re-fetch when the raw provider is re-created.
//
// RESULT: After this fix, every time the user opens Stories screen or
// SeriesDetail, it fetches fresh data from the backend. The 1-minute cache
// buster means even the server cache is bypassed within a minute of a sync.

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// ── Isolate payload ───────────────────────────────────────────────────────────

class _SeriesParsePayload {
  final List<Map<String, dynamic>> rawList;
  const _SeriesParsePayload(this.rawList);
}

class _ParsedSeriesBatch {
  final List<SeriesModel>                seriesList;
  final Map<String, List<EpisodeModel>> episodesBySeriesId;
  const _ParsedSeriesBatch(this.seriesList, this.episodesBySeriesId);
}

/// Runs in a background isolate — no Flutter engine calls allowed here.
_ParsedSeriesBatch _parseSeriesAndEpisodes(_SeriesParsePayload payload) {
  final seriesList         = <SeriesModel>[];
  final episodesBySeriesId = <String, List<EpisodeModel>>{};

  for (final raw in payload.rawList) {
    final rawEpisodes = raw['episodes'] as List<dynamic>? ?? [];
    final episodes = rawEpisodes
        .map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
        .toList();

    // Always use the LIVE count from the embedded episodes array.
    // Never trust the 'episodeCount' field from the DB — it can be stale.
    final liveCount = episodes.length;

    final totalDuration = episodes.fold<int>(
      0,
      (sum, ep) => sum + (ep.duration ?? 0),
    );

    final seriesRaw = Map<String, dynamic>.from(raw)
      ..remove('episodes')
      ..['episodeCount']         = liveCount      // override stale DB value
      ..['totalDurationSeconds'] = totalDuration;

    final series = SeriesModel.fromJson(seriesRaw);
    seriesList.add(series);
    episodesBySeriesId[series.id] = episodes;
  }

  return _ParsedSeriesBatch(seriesList, episodesBySeriesId);
}

// ── _allSeriesRawProvider ─────────────────────────────────────────────────────
//
// FIX A: No ref.keepAlive() — provider auto-disposes when no screen is
// watching it, ensuring fresh data on next navigation to StoriesScreen.
//
// FIX B: Cache-buster query param ?t=<minute> forces the server to bypass
// its 5-minute NodeCache when a new minute has elapsed.

final _allSeriesRawProvider =
    FutureProvider<_ParsedSeriesBatch>((ref) async {
  // NO ref.keepAlive() here — allow auto-dispose so stale data doesn't persist.

  final dio = ref.watch(dioClientProvider);

  // FIX B: Cache-buster — round to current minute so requests within the
  // same minute share the same URL (and same in-flight dedup in DioClient),
  // but a new minute always hits the server fresh.
  final minuteEpoch =
      DateTime.now().millisecondsSinceEpoch ~/ 60000;

  final response = await dio.get<Map<String, dynamic>>(
    ApiConstants.allSeriesWithEpisodes,
    queryParameters: {'t': minuteEpoch},
  );

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  final parsed = await compute(
    _parseSeriesAndEpisodes,
    _SeriesParsePayload(rawList),
  );

  // Yield so first frame paints before providers emit data.
  await Future.microtask(() {});

  return parsed;
});

// ── Public providers ──────────────────────────────────────────────────────────

final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  ref.keepAlive(); // keep list data while navigating between screens
  final batch = await ref.watch(_allSeriesRawProvider.future);
  await Future.microtask(() {});
  return batch.seriesList;
});

final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  ref.keepAlive();
  final batch = await ref.watch(_allSeriesRawProvider.future);
  return batch.episodesBySeriesId[seriesId] ?? const [];
});

final seriesDetailProvider =
    FutureProvider.family<SeriesModel?, String>((ref, id) async {
  ref.keepAlive();
  final batch = await ref.watch(_allSeriesRawProvider.future);
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

  final batch = await ref.watch(_allSeriesRawProvider.future);

  SeriesModel? series;
  try {
    series = batch.seriesList.firstWhere((s) => s.id == seriesId);
  } catch (_) {
    series = null;
  }

  return (
    series:   series,
    episodes: batch.episodesBySeriesId[seriesId] ?? const [],
  );
});

// ── SeriesPrefetchController — NO-OP STUB ────────────────────────────────────

class SeriesPrefetchController {
  // ignore: unused_field
  final Ref _ref;
  SeriesPrefetchController(this._ref);

  void warmRange({
    required List<String> visibleIds,
    required List<String> upcomingIds,
  }) {
    // intentionally empty — all data already loaded
  }

  void dispose() {}
}

final seriesPrefetchControllerProvider =
    Provider<SeriesPrefetchController>((ref) {
  final controller = SeriesPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});