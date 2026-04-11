// lib/features/calm_stories/providers/calm_stories_provider.dart
//
// PERF FIX — Mirrors the calm_music_provider.dart single-endpoint pattern
// ========================================================================
//
// BEFORE (old fan-out approach):
//   Flutter startup fired:
//     1 × GET /api/series                          → list
//     N × GET /api/series/:id                      → detail per series
//     N × GET /api/series/:id/episodes             → episodes per series
//   = 1 + 2N requests simultaneously.
//   With 5 series: 11 requests; with 20 series: 41 requests.
//   All hit DB at once → Prisma P2024 pool timeout → HTTP 503 on Render free tier.
//
// AFTER (this file):
//   Flutter fires:
//     1 × GET /api/series/all-with-episodes        → EVERYTHING in one shot
//   = 1 request, 1 DB query, cached 5 min server-side.
//   At 10,000 users: still only 1 DB query per 5 minutes regardless of load.
//
// HOW IT WORKS (identical architecture to calm_music_provider.dart):
//   _allSeriesRawProvider    — fetches the combined endpoint ONCE, kept alive.
//   seriesListProvider       — pure in-memory slice from the raw cache.
//   episodesProvider         — pure in-memory filter by seriesId, no network.
//   seriesDetailProvider     — pure in-memory lookup by id, no network.
//   seriesWithEpisodesProvider — combines the two above, instant.
//   SeriesPrefetchController — NO-OP stub (everything already loaded).
//
// BACKGROUND ISOLATE PARSING:
//   The JSON decode + model construction runs in a background Dart isolate
//   via compute() so the main thread (and GPU compositor) are not blocked
//   during the first frame paint — fixing the BLASTBufferQueue overflow and
//   "Skipped 72 frames" Choreographer warning.
//
// PUBLIC API — all provider names and return types are IDENTICAL to the old
// file.  Zero changes needed in any screen widget.

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// ── Isolate-safe parse payload & helpers ─────────────────────────────────────

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
    final seriesRaw = Map<String, dynamic>.from(raw)..remove('episodes');
    final series = SeriesModel.fromJson(seriesRaw);
    seriesList.add(series);

    final rawEpisodes = raw['episodes'] as List<dynamic>? ?? [];
    episodesBySeriesId[series.id] = rawEpisodes
        .map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  return _ParsedSeriesBatch(seriesList, episodesBySeriesId);
}

// ── _allSeriesRawProvider ─────────────────────────────────────────────────────

final _allSeriesRawProvider =
    FutureProvider<_ParsedSeriesBatch>((ref) async {
  ref.keepAlive();

  final dio = ref.watch(dioClientProvider);

  final response = await dio.get<Map<String, dynamic>>(
    ApiConstants.allSeriesWithEpisodes,
  );

  final rawData = response['data'] as List<dynamic>? ?? [];
  final rawList = rawData.cast<Map<String, dynamic>>();

  // Parse in background isolate — keeps main thread free for first frame
  final parsed = await compute(
    _parseSeriesAndEpisodes,
    _SeriesParsePayload(rawList),
  );

  // Yield so first frame paints before derived providers emit data
  await Future.microtask(() {});

  return parsed;
});

// ── seriesListProvider ────────────────────────────────────────────────────────

final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  ref.keepAlive();
  final batch = await ref.watch(_allSeriesRawProvider.future);
  await Future.microtask(() {});
  return batch.seriesList;
});

// ── episodesProvider ──────────────────────────────────────────────────────────

final episodesProvider =
    FutureProvider.family<List<EpisodeModel>, String>((ref, seriesId) async {
  ref.keepAlive();
  final batch = await ref.watch(_allSeriesRawProvider.future);
  return batch.episodesBySeriesId[seriesId] ?? const [];
});

// ── seriesDetailProvider ──────────────────────────────────────────────────────

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

// ── seriesWithEpisodesProvider ────────────────────────────────────────────────

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
    series: series,
    episodes: batch.episodesBySeriesId[seriesId] ?? const [],
  );
});

// ── SeriesPrefetchController — NO-OP STUB ────────────────────────────────────
//
// Everything is loaded by _allSeriesRawProvider in a single background-parsed
// batch.  warmRange() is intentionally empty — zero changes needed in
// stories_screen.dart where it is called.

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