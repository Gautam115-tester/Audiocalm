// lib/features/calm_stories/providers/calm_stories_provider.dart
//
// FIXES IN THIS VERSION
// =====================
// 1. episodeCount is now derived from the LIVE episodes array length — not from
//    the stale 'episodeCount' field stored in the DB. This fixes the "80 shown
//    when 81 exist" bug: the backend's episodeCount field can lag behind new
//    syncs, but the embedded episodes list is always current.
//
// 2. totalDurationSeconds is computed per series (sum of all episode durations)
//    and injected into SeriesModel so the UI can show "81 episodes · 14h 23m".
//
// All public provider names and return types are IDENTICAL to the original.
// No screen changes required beyond reading the new fields.

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
    // Parse episodes first so we can derive the live count and total duration.
    final rawEpisodes = raw['episodes'] as List<dynamic>? ?? [];
    final episodes = rawEpisodes
        .map((e) => EpisodeModel.fromJson(e as Map<String, dynamic>))
        .toList();

    // FIX 1: live episode count from the embedded list, not the stale DB field.
    final liveCount = episodes.length;

    // FIX 2: total duration = sum of all episode durations (nulls treated as 0).
    final totalDuration = episodes.fold<int>(
      0,
      (sum, ep) => sum + (ep.duration ?? 0),
    );

    // Build the JSON map for SeriesModel, overriding the stale DB fields.
    final seriesRaw = Map<String, dynamic>.from(raw)
      ..remove('episodes')
      ..['episodeCount']         = liveCount
      ..['totalDurationSeconds'] = totalDuration;

    final series = SeriesModel.fromJson(seriesRaw);
    seriesList.add(series);
    episodesBySeriesId[series.id] = episodes;
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

  // Parse in background isolate — keeps main thread free for first frame paint.
  final parsed = await compute(
    _parseSeriesAndEpisodes,
    _SeriesParsePayload(rawList),
  );

  // Yield so the first frame can paint before derived providers emit data.
  await Future.microtask(() {});

  return parsed;
});

// ── Public providers ──────────────────────────────────────────────────────────

final seriesListProvider = FutureProvider<List<SeriesModel>>((ref) async {
  ref.keepAlive();
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