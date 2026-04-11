// lib/features/calm_stories/providers/completed_episodes_provider.dart
//
// Tracks which episode (and song) IDs the user has completed.
// Persisted in a dedicated Hive box so it survives app restarts.
// Works for both online streaming and offline downloaded playback —
// completion is detected in audio_player_provider.dart by watching
// ProcessingState.completed from the audio engine.
//
// Usage:
//   // Read in a widget:
//   final isDone = ref.watch(
//     completedEpisodesProvider.select((s) => s.contains(episodeId)),
//   );
//
//   // Mark done (called automatically from AudioPlayerNotifier):
//   ref.read(completedEpisodesProvider.notifier).markCompleted(id);
//
//   // Mark undone (long-press the heart button on the tile):
//   ref.read(completedEpisodesProvider.notifier).markIncomplete(id);

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../core/constants/app_constants.dart';

const _kPrefix = 'done_';

class CompletedEpisodesNotifier extends StateNotifier<Set<String>> {
  CompletedEpisodesNotifier() : super(const {}) {
    _load();
  }

  void _load() {
    try {
      final box = Hive.box(AppConstants.completedEpisodesBox);
      final ids = box.keys
          .cast<String>()
          .where((k) => k.startsWith(_kPrefix))
          .map((k) => k.substring(_kPrefix.length))
          .toSet();
      state = ids;
    } catch (_) {}
  }

  bool isCompleted(String id) => state.contains(id);

  Future<void> markCompleted(String id) async {
    if (state.contains(id)) return;
    try {
      final box = Hive.box(AppConstants.completedEpisodesBox);
      await box.put('$_kPrefix$id', true);
      state = {...state, id};
    } catch (_) {}
  }

  Future<void> markIncomplete(String id) async {
    if (!state.contains(id)) return;
    try {
      final box = Hive.box(AppConstants.completedEpisodesBox);
      await box.delete('$_kPrefix$id');
      state = state.difference({id});
    } catch (_) {}
  }

  Future<void> clearAll() async {
    try {
      final box  = Hive.box(AppConstants.completedEpisodesBox);
      final keys = box.keys.cast<String>().where((k) => k.startsWith(_kPrefix)).toList();
      await box.deleteAll(keys);
      state = const {};
    } catch (_) {}
  }
}

final completedEpisodesProvider =
    StateNotifierProvider<CompletedEpisodesNotifier, Set<String>>((ref) {
  return CompletedEpisodesNotifier();
});