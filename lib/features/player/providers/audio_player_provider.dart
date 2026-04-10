// lib/features/player/providers/audio_player_provider.dart
//
// Unchanged except: durationStream and positionStream now emit UNIFIED values
// (handler accumulates part offsets), so the seekbar shows the correct total
// duration and continuous position across all parts automatically.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import '../services/audio_handler.dart';
import '../../../../core/constants/app_constants.dart';

class AudioPlayerState {
  final PlayableItem? currentItem;
  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration? duration;
  final double speed;
  final ja.LoopMode loopMode;
  final bool shuffleMode;
  final List<PlayableItem> queue;
  final int currentIndex;
  final String? error;

  const AudioPlayerState({
    this.currentItem,
    this.isPlaying = false,
    this.isLoading = false,
    this.position = Duration.zero,
    this.duration,
    this.speed = 1.0,
    this.loopMode = ja.LoopMode.off,
    this.shuffleMode = false,
    this.queue = const [],
    this.currentIndex = 0,
    this.error,
  });

  bool get hasMedia => currentItem != null;

  AudioPlayerState copyWith({
    PlayableItem? currentItem,
    bool? isPlaying,
    bool? isLoading,
    Duration? position,
    Duration? duration,
    double? speed,
    ja.LoopMode? loopMode,
    bool? shuffleMode,
    List<PlayableItem>? queue,
    int? currentIndex,
    String? error,
  }) =>
      AudioPlayerState(
        currentItem: currentItem ?? this.currentItem,
        isPlaying: isPlaying ?? this.isPlaying,
        isLoading: isLoading ?? this.isLoading,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        speed: speed ?? this.speed,
        loopMode: loopMode ?? this.loopMode,
        shuffleMode: shuffleMode ?? this.shuffleMode,
        queue: queue ?? this.queue,
        currentIndex: currentIndex ?? this.currentIndex,
        error: error,
      );
}

class AudioPlayerNotifier extends StateNotifier<AudioPlayerState> {
  final AudioCalmHandler _handler;
  final List<StreamSubscription> _subs = [];

  AudioPlayerNotifier(this._handler) : super(const AudioPlayerState()) {
    _init();
  }

  void _init() {
    // positionStream now emits UNIFIED position (handler adds part offsets)
    _subs.add(_handler.positionStream.listen((pos) {
      state = state.copyWith(position: pos);
      _savePosition();
    }));

    // durationStream now emits UNIFIED duration (DB total or accumulated)
    _subs.add(_handler.durationStream.listen((dur) {
      if (dur != null && dur > Duration.zero) {
        state = state.copyWith(duration: dur);
      }
    }));

    _subs.add(_handler.playerStateStream.listen((ps) {
      state = state.copyWith(
        isPlaying: ps.playing,
        isLoading: ps.processingState == ja.ProcessingState.loading ||
            ps.processingState == ja.ProcessingState.buffering,
      );
    }));

    _subs.add(_handler.mediaItem.listen((item) {
      if (item != null) {
        final idx = _handler.currentIndex;
        if (idx < state.queue.length) {
          state = state.copyWith(currentItem: state.queue[idx]);
        }
      }
    }));
  }

  void _savePosition() {
    try {
      if (state.currentItem != null) {
        final box = Hive.box(AppConstants.playbackBox);
        box.put(AppConstants.lastMediaIdKey, state.currentItem!.id);
        box.put(AppConstants.lastPositionKey, state.position.inMilliseconds);
      }
    } catch (_) {}
  }

  Future<void> playItem(PlayableItem item,
      {List<PlayableItem>? queue, int index = 0}) async {
    final q = queue ?? [item];
    state = state.copyWith(
      currentItem: item,
      queue: q,
      currentIndex: index,
      isLoading: true,
      error: null,
      // Reset position/duration immediately so the old values don't flash
      position: Duration.zero,
      duration: item.duration != null ? Duration(seconds: item.duration!) : null,
    );
    try {
      await _handler.playItem(item, queue: queue, index: index);
      _saveToHistory(item);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void _saveToHistory(PlayableItem item) {
    try {
      final box = Hive.box(AppConstants.continueListeningBox);
      final key = 'item_${item.id}';
      final json = item.toJson();
      json['lastPlayedAt'] = DateTime.now().toIso8601String();
      box.put(key, json);
      if (box.length > AppConstants.continueListeningMaxItems) {
        box.delete(box.keys.first);
      }
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    if (state.isPlaying) {
      await _handler.pause();
    } else {
      await _handler.play();
    }
  }

  Future<void> seek(Duration position) => _handler.seek(position);

  Future<void> skipForward()  => _handler.seekForwardOnce();
  Future<void> skipBackward() => _handler.seekBackwardOnce();

  Future<void> skipToNext()     => _handler.skipToNext();
  Future<void> skipToPrevious() => _handler.skipToPrevious();

  Future<void> setSpeed(double speed) async {
    await _handler.setSpeed(speed);
    state = state.copyWith(speed: speed);
  }

  Future<void> cycleLoopMode() async {
    final nextMode = switch (state.loopMode) {
      ja.LoopMode.off => ja.LoopMode.one,
      ja.LoopMode.one => ja.LoopMode.all,
      ja.LoopMode.all => ja.LoopMode.off,
    };
    await _handler.setLoopMode(nextMode);
    state = state.copyWith(loopMode: nextMode);
  }

  Future<void> toggleShuffle() async {
    await _handler.toggleShuffle();
    state = state.copyWith(shuffleMode: !state.shuffleMode);
  }

  @override
  void dispose() {
    for (final sub in _subs) { sub.cancel(); }
    super.dispose();
  }
}

// ── Providers ──────────────────────────────────────────────────────────────

final audioHandlerProvider = Provider<AudioCalmHandler>((ref) {
  throw UnimplementedError('Must be initialized in main');
});

final audioPlayerProvider =
    StateNotifierProvider<AudioPlayerNotifier, AudioPlayerState>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return AudioPlayerNotifier(handler);
});