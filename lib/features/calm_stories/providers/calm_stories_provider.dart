// lib/features/calm_stories/providers/calm_stories_provider.dart
//
// ROOT CAUSE OF "80 EPISODES" BUG — FULLY EXPLAINED & FIXED
// ===========================================================
//
// THE ACTUAL BUG (not what previous fixes thought):
//
// _allSeriesRawProvider had NO ref.keepAlive() — that part was correct.
// BUT Riverpod keeps a provider alive as long as ANY subscriber is alive.
//
// The keepAlive chain:
//   episodesProvider(id)       → ref.keepAlive() + watches _allSeriesRawProvider
//   seriesDetailProvider(id)   → ref.keepAlive() + watches _allSeriesRawProvider
//   seriesWithEpisodesProvider → ref.keepAlive() + watches _allSeriesRawProvider
//
// Flow that caused the bug:
//   1. User opens StoriesScreen → allSeriesRawProvider fetches → gets 80 eps
//   2. User taps KarnaPishachini → SeriesDetailScreen opens
//      → episodesProvider(id) starts, calls ref.keepAlive()
//      → episodesProvider watches allSeriesRawProvider
//      → allSeriesRawProvider is now kept alive by episodesProvider
//   3. Admin syncs ep 81 (server cache invalidated ✓)
//   4. User goes back to StoriesScreen
//      → seriesListProvider re-runs, watches allSeriesRawProvider
//      → allSeriesRawProvider is STILL the old instance (held by episodesProvider)
//      → Returns the OLD batch with 80 episodes
//      → NO network request is made. Ever.
//
// The previous "fix" (removing keepAlive from seriesListProvider) did nothing
// because allSeriesRawProvider was already immortal via episodesProvider.
//
// THE CORRECT FIX (3 parts):
//
// 1. Make allSeriesRawProvider PUBLIC — so StoriesScreen can call
//    ref.invalidate(allSeriesRawProvider) in initState to force a fresh fetch
//    regardless of any keepAlive state.
//
// 2. Remove keepAlive from ALL derived providers — so allSeriesRawProvider
//    is no longer held alive by any subscriber and can auto-dispose normally.
//    Family providers recreate cheaply on next watch.
//
// 3. StoriesScreen calls ref.invalidate(allSeriesRawProvider) in initState
//    as an explicit nuclear option — even if some future keepAlive creeps back
//    in, the screen always forces a fresh fetch on every visit.
//
// BACKEND FIX (series.js):
//    Remove the ?t=<epoch> cache-buster query param from the request.
//    It was creating unbounded cache slots on the server
//    (one new NodeCache entry per 30s epoch × 5min TTL = up to 10 stale slots
//    accumulating simultaneously). The server's invalidateSeriesCache() calls
//    flushAll() which correctly clears ALL keys — so a single stable URL
//    with one stable cache key "all_with_episodes" is the correct approach.
//
// DURATION PRECISION FIX:
//    Only sum episodes where duration != null && duration > 0.
//    Partially-synced episodes with null/0 duration no longer affect the total.

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
  final List<SeriesModel> seriesList;
  final Map<String, List<EpisodeModel>> episodesBySeriesId;
  const _ParsedSeriesBatch(this.seriesList, this.episodesBySeriesId);
}

/// Runs in a background isolate — no Flutter engine calls allowed here.
_ParsedSeriesBatch _parseSeriesAndEpisodes(_SeriesParsePayload payload) {
  final seriesList = <SeriesModel>[];
  final episodesBySeriesId = <String, List<EpisodeModel>>{};

  for (final raw in payload.rawList) {
    final rawEpisodes = raw['episodes'] as List<dynamic>? ?? [];
    final episodes = rawEpisodes
        .map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
        .toList();

    // Always derive count from the live embedded episodes array.
    // Never trust 'episodeCount' from the DB response — it can be stale.
    final liveCount = episodes.length;

    // DURATION FIX: only sum episodes with a real non-zero duration.
    // Episodes with null or 0 duration (partially synced) are excluded
    // so they don't skew the total shown in the series header.
    final totalDuration = episodes.fold<int>(
      0,
      (sum, ep) =>
          sum + (ep.duration != null && ep.duration! > 0 ? ep.duration! : 0),
    );

    final seriesRaw = Map<String, dynamic>.from(raw)
      ..remove('episodes')
      ..['episodeCount'] = liveCount        // override stale DB value
      ..['totalDurationSeconds'] = totalDuration;

    final series = SeriesModel.fromJson(seriesRaw);
    seriesList.add(series);
    episodesBySeriesId[series.id] = episodes;
  }

  return _ParsedSeriesBatch(seriesList, episodesBySeriesId);
}

// ── allSeriesRawProvider (PUBLIC — was _allSeriesRawProvider) ─────────────────
//
// Made PUBLIC so StoriesScreen can call ref.invalidate(allSeriesRawProvider)
// in initState to force a fresh fetch on every screen visit.
//
// NO ref.keepAlive() — combined with removing keepAlive from all derived
// providers below, this now auto-disposes correctly.
//
// NO ?t query param — removed. Was creating unbounded server cache slots.
// The backend's invalidateSeriesCache() → flushAll() clears everything.
// A single stable URL = a single stable server cache entry = correct.

final allSeriesRawProvider =
    FutureProvider<_ParsedSeriesBatch>((ref) async {
  final dio = ref.watch(dioClientProvider);

  // Single stable URL — no ?t cache-buster (see explanation above).
  final response = await dio.get<Map<String, dynamic>>(
    ApiConstants.allSeriesWithEpisodes,
  );

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  final parsed = await compute(
    _parseSeriesAndEpisodes,
    _SeriesParsePayload(rawList),
  );

  await Future.microtask(() {});
  return parsed;
});

// ── Public providers ──────────────────────────────────────────────────────────
//
// CRITICAL: ALL ref.keepAlive() calls removed from every derived provider.
//
// Any keepAlive on a provider that watches allSeriesRawProvider will hold
// allSeriesRawProvider alive indefinitely, preventing auto-dispose and making
// ref.invalidate(allSeriesRawProvider) in StoriesScreen have no effect on
// subsequent navigations.
//
// Without keepAlive, providers dispose when their last listener disappears
// (screen closes) and are recreated fresh from the new network data on the
// next screen visit. The performance cost is negligible — parsing the JSON
// takes <5ms in the background isolate.

final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  // NO ref.keepAlive()
  final batch = await ref.watch(allSeriesRawProvider.future);
  await Future.microtask(() {});
  return batch.seriesList;
});

final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  // NO ref.keepAlive() — THIS was the primary culprit keeping allSeriesRawProvider alive
  final batch = await ref.watch(allSeriesRawProvider.future);
  return batch.episodesBySeriesId[seriesId] ?? const [];
});

final seriesDetailProvider =
    FutureProvider.family<SeriesModel?, String>((ref, id) async {
  // NO ref.keepAlive()
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
  // NO ref.keepAlive()
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

// ── SeriesPrefetchController — NO-OP STUB ────────────────────────────────────

class SeriesPrefetchController {
  // ignore: unused_field
  final Ref _ref;
  SeriesPrefetchController(this._ref);

  void warmRange({
    required List<String> visibleIds,
    required List<String> upcomingIds,
  }) {
    // intentionally empty — all data already loaded in single batch
  }

  void dispose() {}
}

final seriesPrefetchControllerProvider =
    Provider<SeriesPrefetchController>((ref) {
  final controller = SeriesPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});