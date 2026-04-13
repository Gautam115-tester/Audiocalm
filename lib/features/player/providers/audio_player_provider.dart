// lib/features/player/providers/audio_player_provider.dart
//
// FIXES IN THIS VERSION
// =====================
//
// FIX 1 — AUTO-PLAY NEXT ALBUM WHEN CURRENT ALBUM COMPLETES
// ----------------------------------------------------------
// AudioPlayerNotifier now sets _handler.onQueueExhausted to a callback that:
//   1. Reads allAlbumsRawProvider to get the full ordered album list.
//   2. Finds the currently playing album by matching any song's albumId.
//   3. Gets the next album in the list (wraps to first if at the end).
//   4. Builds a PlayableItem queue from that album's songs.
//   5. Calls _handler.playItem() with the new queue.
// This makes album playback continuous — finishing an album seamlessly
// starts the next one, exactly like a music player queue.
//
// FIX 2 — RESUME AUDIO SERIES FROM LAST SAVED POSITION
// -----------------------------------------------------
// playItem() now accepts a `resumeFromSaved` parameter.
// For EPISODES this defaults to TRUE so that tapping an episode that has a
// saved position automatically resumes from where the user left off.
// For SONGS this defaults to FALSE — songs always start from the beginning.
// The caller (series_detail_screen, album_detail_screen, downloads_screen)
// can override this per tap if needed.
//
// The actual seek logic is inside AudioCalmHandler._loadItem() — the
// provider layer just passes the flag through.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import '../services/audio_handler.dart';
import '../../../../core/constants/app_constants.dart';
import '../../calm_stories/providers/completed_episodes_provider.dart';
// FIX 1: import album provider to resolve next-album queue
import '../../calm_music/providers/calm_music_provider.dart';
import '../../calm_music/data/models/song_model.dart';
import '../../../core/constants/api_constants.dart';
import 'package:flutter/foundation.dart';


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
    this.isPlaying   = false,
    this.isLoading   = false,
    this.position    = Duration.zero,
    this.duration,
    this.speed       = 1.0,
    this.loopMode    = ja.LoopMode.off,
    this.shuffleMode = false,
    this.queue       = const [],
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
        currentItem:  currentItem  ?? this.currentItem,
        isPlaying:    isPlaying    ?? this.isPlaying,
        isLoading:    isLoading    ?? this.isLoading,
        position:     position     ?? this.position,
        duration:     duration     ?? this.duration,
        speed:        speed        ?? this.speed,
        loopMode:     loopMode     ?? this.loopMode,
        shuffleMode:  shuffleMode  ?? this.shuffleMode,
        queue:        queue        ?? this.queue,
        currentIndex: currentIndex ?? this.currentIndex,
        error:        clearError ? null : (error ?? this.error),
      );
}

class AudioPlayerNotifier extends StateNotifier<AudioPlayerState> {
  final AudioCalmHandler _handler;
  final Ref _ref;
  final List<StreamSubscription> _subs = [];

  AudioPlayerNotifier(this._handler, this._ref)
      : super(const AudioPlayerState()) {
    _init();
  }

  void _init() {
    // FIX 1: Register the queue-exhausted callback so the handler can
    // request the next album's songs when the current album finishes.
    _handler.onQueueExhausted = _onQueueExhausted;

    _subs.add(_handler.positionStream.listen((pos) {
      state = state.copyWith(position: pos);
      _savePosition();
    }));

    _subs.add(_handler.durationStream.listen((dur) {
      if (dur != null && dur > Duration.zero) {
        state = state.copyWith(duration: dur);
      }
    }));

    _subs.add(_handler.playerStateStream.listen((ps) {
      if (ps.processingState == ja.ProcessingState.completed &&
          state.currentItem != null) {
        _ref
            .read(completedEpisodesProvider.notifier)
            .markCompleted(state.currentItem!.id);
      }

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

  // ── FIX 1: Queue-exhausted handler ─────────────────────────────────────────
  // Called by AudioCalmHandler when the last song of the current queue finishes
  // and loopMode == off. We find the next album in allAlbumsRawProvider and
  // start playing it from the first song.
  void _onQueueExhausted() {
    // Run async work off the hot path — handler callback must return quickly.
    _loadAndPlayNextAlbum();
  }

  Future<void> _loadAndPlayNextAlbum() async {
    try {
      // 1. Get the full album+songs batch (already cached by the provider).
      final batch = await _ref.read(allAlbumsRawProvider.future);
      if (batch.albums.isEmpty) return;

      // 2. Identify the current album from the playing item.
      //    Songs carry albumId in their streamUrl path OR we can match by
      //    looking at which album's song list contains the current item id.
      final currentItemId = state.currentItem?.id;
      if (currentItemId == null) return;

      String? currentAlbumId;
      for (final entry in batch.songsByAlbumId.entries) {
        if (entry.value.any((s) => s.id == currentItemId)) {
          currentAlbumId = entry.key;
          break;
        }
      }

      // 3. If the current item isn't a song (e.g. it's an episode), don't
      //    auto-advance albums — episodes have their own series queue logic.
      if (currentAlbumId == null) return;

      // 4. Find the current album's position in the ordered list.
      final albums = batch.albums;
      final currentAlbumIndex = albums.indexWhere((a) => a.id == currentAlbumId);
      if (currentAlbumIndex < 0) return;

      // 5. Get the next album (wrap around to first when at end).
      final nextAlbumIndex = (currentAlbumIndex + 1) % albums.length;
      final nextAlbum      = albums[nextAlbumIndex];
      final nextSongs      = batch.songsByAlbumId[nextAlbum.id] ?? [];
      if (nextSongs.isEmpty) return;

      // 6. Build the PlayableItem queue for the next album.
      final queue = nextSongs.map((s) => _songToPlayable(s, nextAlbum)).toList();

      debugPrint('[AudioPlayerNotifier] Auto-advancing to album "${nextAlbum.title}" '
          '(${queue.length} songs)');

      // 7. Play the first song of the next album — no resume (fresh start).
      await playItem(queue.first, queue: queue, index: 0);

    } catch (e) {
      debugPrint('[AudioPlayerNotifier] _loadAndPlayNextAlbum error: $e');
      // Non-fatal — player simply stays idle if this fails.
    }
  }

  /// Convert a SongModel + album into a PlayableItem.
  PlayableItem _songToPlayable(SongModel song, dynamic album) {
    return PlayableItem(
      id:         song.id,
      title:      song.title,
      subtitle:   album?.title as String?,
      artworkUrl: song.coverUrl ?? album?.coverUrl as String?,
      duration:   song.duration,
      partCount:  song.isMultiPart ? 2 : 1,
      type:       MediaType.song,
      streamUrl:  '${ApiConstants.baseUrl}${ApiConstants.songStream(song.id)}',
    );
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

  // ── FIX 2: resumeFromSaved parameter ───────────────────────────────────────
  // For episodes: defaults to true so tapping resumes from last position.
  // For songs:    defaults to false so songs always start from the beginning.
  // Callers can explicitly set resumeFromSaved to override the default.
  Future<void> playItem(
    PlayableItem item, {
    List<PlayableItem>? queue,
    int index = 0,
    bool? resumeFromSaved,
  }) async {
    final q = queue ?? [item];

    // Determine whether to resume: episodes resume by default, songs don't.
    final shouldResume = resumeFromSaved ?? (item.type == MediaType.episode);

    state = state.copyWith(
      currentItem:  item,
      queue:        q,
      currentIndex: index,
      isPlaying:    false,
      isLoading:    true,
      error:        null,
      position:     Duration.zero,
      duration:     item.duration != null ? Duration(seconds: item.duration!) : null,
    );

    _handler
        .playItem(item, queue: queue, index: index, resumeFromSaved: shouldResume)
        .then((_) {
          _saveToHistory(item);
        })
        .catchError((e) {
          if (mounted) {
            state = state.copyWith(isLoading: false, error: e.toString());
          }
        });
  }

  void _saveToHistory(PlayableItem item) {
    try {
      final box  = Hive.box(AppConstants.continueListeningBox);
      final key  = 'item_${item.id}';
      final json = item.toJson();
      json['lastPlayedAt'] = DateTime.now().toIso8601String();
      box.put(key, json);
      if (box.length > AppConstants.continueListeningMaxItems) {
        box.delete(box.keys.first);
      }
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    if (state.isPlaying) await _handler.pause();
    else await _handler.play();
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

  /// LOOP ORDER:
  ///   off  →  all  : repeat whole album/queue forever
  ///   all  →  one  : repeat single track forever
  ///   one  →  off  : no repeat
  Future<void> cycleLoopMode() async {
    final nextMode = switch (state.loopMode) {
      ja.LoopMode.off => ja.LoopMode.all,
      ja.LoopMode.all => ja.LoopMode.one,
      ja.LoopMode.one => ja.LoopMode.off,
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
    // Clear the callback to avoid a dangling reference after disposal.
    _handler.onQueueExhausted = null;
    for (final sub in _subs) { sub.cancel(); }
    super.dispose();
  }
}

// ── Providers ─────────────────────────────────────────────────────────────────

final audioHandlerProvider = Provider<AudioCalmHandler>((ref) {
  throw UnimplementedError('Must be initialized in main');
});

final audioPlayerProvider =
    StateNotifierProvider<AudioPlayerNotifier, AudioPlayerState>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return AudioPlayerNotifier(handler, ref);
});