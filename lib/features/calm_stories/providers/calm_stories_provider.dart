// lib/features/calm_stories/providers/calm_stories_provider.dart
//
// Mirrors the music fix: prefetches BOTH seriesDetailProvider AND
// episodesProvider per series so seriesWithEpisodesProvider (which needs
// both) resolves instantly from cache when user taps.

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/series_model.dart';
import '../data/models/episode_model.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/di/providers.dart';

// ── Series list ──────────────────────────────────────────────────────────────

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

// ── Episodes (per series) ────────────────────────────────────────────────────

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

// ── Series detail ────────────────────────────────────────────────────────────

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

// ── Combined (parallel fetch) ─────────────────────────────────────────────────

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

// ── Smart Prefetch Controller ─────────────────────────────────────────────────
//
// FIX: Warms BOTH seriesDetailProvider AND episodesProvider per series.
// seriesWithEpisodesProvider needs both → finds everything in cache on tap.

class SeriesPrefetchController {
  final Ref _ref;

  final Set<String> _cached = {};
  Timer? _debounce;
  bool _cancelled = false;

  SeriesPrefetchController(this._ref);

  void warmRange({
    required List<String> visibleIds,
    required List<String> upcomingIds,
  }) {
    for (final id in visibleIds) {
      _prefetchIfNeeded(id);
    }

    _debounce?.cancel();
    _cancelled = true;

    _debounce = Timer(const Duration(milliseconds: 300), () {
      _cancelled = false;
      _prefetchUpcoming(upcomingIds);
    });
  }

  Future<void> _prefetchUpcoming(List<String> ids) async {
    for (final id in ids) {
      if (_cancelled) return;
      await _prefetchIfNeeded(id);
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> _prefetchIfNeeded(String seriesId) async {
    if (_cached.contains(seriesId)) return;
    _cached.add(seriesId);
    try {
      // FIX: warm BOTH providers — seriesWithEpisodesProvider needs both
      await Future.wait([
        _ref.read(seriesDetailProvider(seriesId).future),
        _ref.read(episodesProvider(seriesId).future),
      ]);
    } catch (_) {
      _cached.remove(seriesId);
    }
  }

  void dispose() {
    _debounce?.cancel();
    _cancelled = true;
  }
}

final seriesPrefetchControllerProvider =
    Provider<SeriesPrefetchController>((ref) {
  final controller = SeriesPrefetchController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});