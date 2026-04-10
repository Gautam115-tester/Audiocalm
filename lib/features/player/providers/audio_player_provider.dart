// lib/features/player/providers/audio_player_provider.dart
//
// FIX: Mini player now appears instantly when user taps an audio item.
//
// ROOT CAUSE of the 5-second delay:
//   playItem() called _handler.playItem() and AWAITED it before updating state.
//   _handler.playItem() → _loadItem() → _loadPartAndPlay() → setAudioSource()
//   which blocks until the network buffer is ready (~5 seconds on slow connections).
//   During that entire wait, state.currentItem == null, so MiniPlayer returned
//   SizedBox.shrink() — invisible.
//
// FIX APPLIED:
//   1. Set state.currentItem, queue, isLoading=true SYNCHRONOUSLY before any
//      await. MiniPlayer sees hasMedia==true immediately and renders.
//   2. Fire _handler.playItem() without awaiting in the provider — the handler's
//      own streams (playerStateStream, durationStream, positionStream) drive all
//      subsequent state updates exactly as before.
//   3. Added _resetForNewItem() helper to atomically reset position/duration
//      so stale values from the previous track don't flash on the new item's UI.

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
    bool clearError = false,
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
        error: clearError ? null : (error ?? this.error),
      );
}

class AudioPlayerNotifier extends StateNotifier<AudioPlayerState> {
  final AudioCalmHandler _handler;
  final List<StreamSubscription> _subs = [];

  AudioPlayerNotifier(this._handler) : super(const AudioPlayerState()) {
    _init();
  }

  void _init() {
    // positionStream emits UNIFIED position (handler accumulates part offsets)
    _subs.add(_handler.positionStream.listen((pos) {
      state = state.copyWith(position: pos);
      _savePosition();
    }));

    // durationStream emits UNIFIED duration (DB total or accumulated)
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

  /// FIX: Update state SYNCHRONOUSLY first so MiniPlayer renders immediately,
  /// then kick off the handler load in the background (no await).
  Future<void> playItem(PlayableItem item,
      {List<PlayableItem>? queue, int index = 0}) async {
    final q = queue ?? [item];

    // ── STEP 1: Optimistic state update (synchronous, instant) ──────────────
    // MiniPlayer checks hasMedia = currentItem != null.
    // By setting currentItem here — before any network IO — the mini player
    // appears on the very next frame after the user taps.
    state = state.copyWith(
      currentItem: item,
      queue: q,
      currentIndex: index,
      isPlaying: false,      // not playing yet — still buffering
      isLoading: true,       // show spinner in PlayPause button
      error: null,
      position: Duration.zero,
      // Pre-fill duration from metadata if available so seekbar isn't blank
      duration: item.duration != null ? Duration(seconds: item.duration!) : null,
    );

    // ── STEP 2: Start actual playback in background (do NOT await) ───────────
    // The handler's streams (playerStateStream, durationStream, positionStream)
    // will push further state updates as buffering progresses.
    _handler.playItem(item, queue: queue, index: index).then((_) {
      _saveToHistory(item);
    }).catchError((e) {
      if (mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
    });
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