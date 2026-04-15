// lib/features/player/providers/audio_player_provider.dart
//
// EQUALIZER FIX
// =============
// Wires handler.onAudioSessionChanged → equalizerProvider.reinitialize()
// so the EQ is always bound to the correct Android audio session ID.
// All other logic unchanged.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import '../services/audio_handler.dart';
import '../services/playback_position_service.dart';
import '../services/equalizer_service.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/constants/api_constants.dart';
import '../../calm_stories/providers/calm_stories_provider.dart';
import '../../calm_music/providers/calm_music_provider.dart';
import '../../calm_music/data/models/song_model.dart';
import '../../calm_stories/providers/completed_episodes_provider.dart';

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
    _handler.onQueueExhausted = _onQueueExhausted;
    _handler.onGetNextAlbumFirstTrack = _getNextAlbumFirstTrack;

    // EQ FIX: Wire the audio session ID callback so the equalizer always
    // binds to the real ExoPlayer session. The handler calls this whenever
    // a new track starts (with a 300ms delay so ExoPlayer has assigned its ID).
    _handler.onAudioSessionChanged = (int sessionId) {
      debugPrint('[AudioPlayerNotifier] Reinitializing EQ for session $sessionId');
      _ref.read(equalizerProvider.notifier).reinitialize(sessionId);
    };

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

    Future.delayed(const Duration(milliseconds: 500), _restoreLastSession);
  }

  // ── NEW: Provide next album's first track to handler ───────────────────────

  Future<PlayableItem?> _getNextAlbumFirstTrack() async {
    try {
      final batch = await _ref.read(allAlbumsRawProvider.future)
          .timeout(const Duration(seconds: 8));
      if (batch.albums.isEmpty) return null;

      final currentItemId = state.currentItem?.id;
      if (currentItemId == null) return null;

      String? currentAlbumId;
      for (final entry in batch.songsByAlbumId.entries) {
        if (entry.value.any((s) => s.id == currentItemId)) {
          currentAlbumId = entry.key;
          break;
        }
      }
      if (currentAlbumId == null) return null;

      final albums          = batch.albums;
      final currentAlbumIdx = albums.indexWhere((a) => a.id == currentAlbumId);
      if (currentAlbumIdx < 0) return null;

      final nextAlbumIdx = (currentAlbumIdx + 1) % albums.length;
      final nextAlbum    = albums[nextAlbumIdx];
      final nextSongs    = batch.songsByAlbumId[nextAlbum.id] ?? [];
      if (nextSongs.isEmpty) return null;

      return _songToPlayable(nextSongs.first, nextAlbum);
    } catch (e) {
      debugPrint('[AudioPlayerNotifier] _getNextAlbumFirstTrack error: $e');
      return null;
    }
  }

  // ── Session restore ────────────────────────────────────────────────────────

  Future<void> _restoreLastSession() async {
    if (!mounted) return;
    try {
      final box         = Hive.box(AppConstants.playbackBox);
      final lastMediaId = box.get(AppConstants.lastMediaIdKey) as String?;
      if (lastMediaId == null || lastMediaId.isEmpty) return;

      final savedPos = PlaybackPositionService.get(lastMediaId);

      // Search episodes first
      try {
        final seriesBatch = await _ref.read(allSeriesRawProvider.future)
            .timeout(const Duration(seconds: 10));

        for (final entry in seriesBatch.episodesBySeriesId.entries) {
          final seriesId = entry.key;
          final episodes = entry.value;
          final epIdx    = episodes.indexWhere((ep) => ep.id == lastMediaId);
          if (epIdx >= 0) {
            final ep     = episodes[epIdx];
            final series = seriesBatch.seriesList
                .firstWhere((s) => s.id == seriesId, orElse: () => seriesBatch.seriesList.first);

            final queue = episodes.map((e) => PlayableItem(
              id:         e.id,
              title:      e.title,
              subtitle:   series.title,
              artworkUrl: series.coverUrl,
              duration:   e.duration,
              partCount:  e.partCount,
              type:       MediaType.episode,
              streamUrl:  '${ApiConstants.baseUrl}${ApiConstants.episodeStream(e.id)}',
            )).toList();

            debugPrint('[AudioPlayerNotifier] Restoring episode "${ep.title}" '
                'at ${savedPos ?? 0}s');

            await playItem(queue[epIdx], queue: queue, index: epIdx, resumeFromSaved: true);
            await Future.delayed(const Duration(milliseconds: 300));
            if (mounted) await _handler.pause();
            return;
          }
        }
      } catch (e) {
        debugPrint('[AudioPlayerNotifier] Could not restore episode: $e');
      }

      // Search songs
      try {
        final albumBatch = await _ref.read(allAlbumsRawProvider.future)
            .timeout(const Duration(seconds: 10));

        for (final entry in albumBatch.songsByAlbumId.entries) {
          final albumId = entry.key;
          final songs   = entry.value;
          final songIdx = songs.indexWhere((s) => s.id == lastMediaId);
          if (songIdx >= 0) {
            final album = albumBatch.albums
                .firstWhere((a) => a.id == albumId, orElse: () => albumBatch.albums.first);

            final queue = songs.map((s) => _songToPlayable(s, album)).toList();

            debugPrint('[AudioPlayerNotifier] Restoring song "${songs[songIdx].title}" '
                'at ${savedPos ?? 0}s');

            await playItem(
              queue[songIdx],
              queue: queue,
              index: songIdx,
              resumeFromSaved: savedPos != null && savedPos > 5,
            );
            await Future.delayed(const Duration(milliseconds: 300));
            if (mounted) await _handler.pause();
            return;
          }
        }
      } catch (e) {
        debugPrint('[AudioPlayerNotifier] Could not restore song: $e');
      }
    } catch (e) {
      debugPrint('[AudioPlayerNotifier] _restoreLastSession error: $e');
    }
  }

  // ── Queue-exhausted handler ────────────────────────────────────────────────

  void _onQueueExhausted() {
    _loadAndPlayNextAlbum();
  }

  Future<void> _loadAndPlayNextAlbum() async {
    try {
      final batch = await _ref.read(allAlbumsRawProvider.future);
      if (batch.albums.isEmpty) return;

      final currentItemId = state.currentItem?.id;
      if (currentItemId == null) return;

      String? currentAlbumId;
      for (final entry in batch.songsByAlbumId.entries) {
        if (entry.value.any((s) => s.id == currentItemId)) {
          currentAlbumId = entry.key;
          break;
        }
      }
      if (currentAlbumId == null) return;

      final albums           = batch.albums;
      final currentAlbumIdx  = albums.indexWhere((a) => a.id == currentAlbumId);
      if (currentAlbumIdx < 0) return;

      final nextAlbumIdx = (currentAlbumIdx + 1) % albums.length;
      final nextAlbum    = albums[nextAlbumIdx];
      final nextSongs    = batch.songsByAlbumId[nextAlbum.id] ?? [];
      if (nextSongs.isEmpty) return;

      final queue = nextSongs.map((s) => _songToPlayable(s, nextAlbum)).toList();
      debugPrint('[AudioPlayerNotifier] Auto-advancing to album "${nextAlbum.title}"');

      state = state.copyWith(
        queue:        queue,
        currentIndex: 0,
        currentItem:  queue.first,
      );
    } catch (e) {
      debugPrint('[AudioPlayerNotifier] _loadAndPlayNextAlbum error: $e');
    }
  }

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

  Future<void> playItem(
    PlayableItem item, {
    List<PlayableItem>? queue,
    int index = 0,
    bool? resumeFromSaved,
  }) async {
    final q            = queue ?? [item];
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
    _handler.onQueueExhausted         = null;
    _handler.onGetNextAlbumFirstTrack = null;
    _handler.onAudioSessionChanged    = null;
    for (final sub in _subs) { sub.cancel(); }
    super.dispose();
  }
}

// ── Providers ──────────────────────────────────────────────────────────────────

final audioHandlerProvider = Provider<AudioCalmHandler>((ref) {
  throw UnimplementedError('Must be initialized in main');
});

final audioPlayerProvider =
    StateNotifierProvider<AudioPlayerNotifier, AudioPlayerState>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return AudioPlayerNotifier(handler, ref);
});