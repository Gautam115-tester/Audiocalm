// lib/features/player/services/audio_handler.dart
//
// MULTI-PART FIX:
// When an episode has partCount > 1, the backend stores fileIds as a JSON
// array and the /stream?part=N endpoint serves each part.
//
// This handler builds a ConcatenatingAudioSource so just_audio plays
// part1 → part2 → … → partN seamlessly as if it were one file.
// The seekbar and duration reflect the TOTAL combined length.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import 'multi_part_resolver.dart';
import 'multi_part_url_service.dart';

class AudioCalmHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final ja.AudioPlayer _player = ja.AudioPlayer();
  final MultiPartUrlService _urlService = MultiPartUrlService(null);

  List<PlayableItem> _playableQueue = [];
  int _currentIndex = 0;
  bool _shuffleMode = false;
  ja.LoopMode _loopMode = ja.LoopMode.off;

  AudioCalmHandler() {
    _init();
  }

  void _init() {
    _player.playbackEventStream.listen((event) {
      _broadcastState(event);
    });

    _player.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed) {
        _handleCompletion();
      }
    });
  }

  Future<void> _handleCompletion() async {
    switch (_loopMode) {
      case ja.LoopMode.one:
        await _player.seek(Duration.zero);
        await _player.play();
        break;
      case ja.LoopMode.all:
        if (_currentIndex < _playableQueue.length - 1) {
          await skipToNext();
        } else {
          _currentIndex = 0;
          if (_playableQueue.isNotEmpty) {
            await _loadAndPlay(_playableQueue[0]);
          }
        }
        break;
      case ja.LoopMode.off:
        if (_currentIndex < _playableQueue.length - 1) {
          await skipToNext();
        }
        break;
    }
  }

  // ── _buildAudioSource ─────────────────────────────────────────────────────
  //
  // Single-part  → UriAudioSource (simple stream URL)
  // Multi-part   → ConcatenatingAudioSource with ?part=1, ?part=2 … ?part=N
  //
  // The concatenating source plays seamlessly: part1 finishes → part2 starts
  // automatically. The seekbar shows the position within the currently-active
  // child source; the total duration becomes available once all parts are
  // buffered.
  //
  // We use LockCachingAudioSource for each part so that:
  //   • Seeking within a part works reliably (Range header support).
  //   • Completed parts are cached locally, avoiding re-download on loop.
  //   • useLazyPreparation = true → next part is buffered while current plays.

  Future<ja.AudioSource> _buildAudioSource(PlayableItem item) async {
    final contentType = item.isEpisode ? 'episodes' : 'songs';

    if (item.partCount <= 1) {
      // Single-part — straightforward stream.
      return ja.AudioSource.uri(
        Uri.parse(item.streamUrl),
        tag: item.id,
      );
    }

    // Multi-part: build ?part=1 … ?part=N without a network call.
    final parts = _urlService.buildPartsFromCount(
      baseId:      item.id,
      contentType: contentType,
      partCount:   item.partCount,
    );

    debugPrint(
      '[AudioHandler] Multi-part "${item.title}": '
      '${parts.length} part(s) → concatenating'
    );

    // Build a ConcatenatingAudioSource that plays parts end-to-end.
    // useLazyPreparation = true: part N+1 is prepared while part N is playing.
    final children = parts.map((p) {
      return ja.AudioSource.uri(
        Uri.parse(p.streamUrl),
        tag: p.partId,
      );
    }).toList();

    return ja.ConcatenatingAudioSource(
      useLazyPreparation: true,
      shuffleOrder: ja.DefaultShuffleOrder(),
      children: children,
    );
  }

  Future<void> _loadAndPlay(PlayableItem item) async {
    try {
      mediaItem.add(_playableToMediaItem(item));
      final source = await _buildAudioSource(item);
      await _player.setAudioSource(source);
      await _player.play();
    } catch (e) {
      debugPrint('[AudioHandler] _loadAndPlay error: $e');
    }
  }

  MediaItem _playableToMediaItem(PlayableItem item) {
    return MediaItem(
      id: item.id,
      title: item.title,
      artist: item.subtitle,
      artUri: item.artworkUrl != null ? Uri.parse(item.artworkUrl!) : null,
      duration: item.durationDuration,
      extras: {
        'type':      item.type.name,
        'streamUrl': item.streamUrl,
        'partCount': item.partCount,
        ...item.extras,
      },
    );
  }

  Future<void> playItem(PlayableItem item,
      {List<PlayableItem>? queue, int index = 0}) async {
    if (queue != null) {
      _playableQueue = queue;
      _currentIndex  = index;
      this.queue.add(queue.map(_playableToMediaItem).toList());
    } else {
      _playableQueue = [item];
      _currentIndex  = 0;
      this.queue.add([_playableToMediaItem(item)]);
    }
    await _loadAndPlay(item);
  }

  @override Future<void> play()  => _player.play();
  @override Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (_currentIndex < _playableQueue.length - 1) {
      _currentIndex++;
      await _loadAndPlay(_playableQueue[_currentIndex]);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else if (_currentIndex > 0) {
      _currentIndex--;
      await _loadAndPlay(_playableQueue[_currentIndex]);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index >= 0 && index < _playableQueue.length) {
      _currentIndex = index;
      await _loadAndPlay(_playableQueue[index]);
    }
  }

  @override
  Future<void> seekForward(bool begin) async {
    if (!begin) return;
    final newPos = _player.position + const Duration(seconds: 15);
    final dur    = _player.duration;
    if (dur != null && newPos < dur) {
      await _player.seek(newPos);
    } else if (dur != null) {
      await _player.seek(dur);
    }
  }

  @override
  Future<void> seekBackward(bool begin) async {
    if (!begin) return;
    final newPos = _player.position - const Duration(seconds: 10);
    await _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
  }

  Future<void> seekForwardOnce()  => seekForward(true);
  Future<void> seekBackwardOnce() => seekBackward(true);

  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setLoopMode(ja.LoopMode mode) async {
    _loopMode = mode;
    await _player.setLoopMode(mode);
  }

  Future<void> toggleShuffle() async {
    _shuffleMode = !_shuffleMode;
    await _player.setShuffleModeEnabled(_shuffleMode);
  }

  // ── Streams / getters ─────────────────────────────────────────────────────
  Stream<Duration>  get positionStream   => _player.positionStream;
  Stream<Duration?> get durationStream   => _player.durationStream;
  Stream<ja.PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<double>    get speedStream      => _player.speedStream;

  Duration  get position     => _player.position;
  Duration? get duration     => _player.duration;
  bool      get playing      => _player.playing;
  double    get speed        => _player.speed;
  int       get currentIndex => _currentIndex;
  List<PlayableItem> get playableQueue => _playableQueue;
  ja.LoopMode get loopMode   => _loopMode;
  bool      get shuffleMode  => _shuffleMode;

  void _broadcastState(ja.PlaybackEvent event) {
    final isPlaying = _player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: {
        ja.ProcessingState.idle:      AudioProcessingState.idle,
        ja.ProcessingState.loading:   AudioProcessingState.loading,
        ja.ProcessingState.buffering: AudioProcessingState.buffering,
        ja.ProcessingState.ready:     AudioProcessingState.ready,
        ja.ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing:          isPlaying,
      updatePosition:   _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed:            _player.speed,
      queueIndex:       _currentIndex,
    ));
  }

  @override
  Future<void> onTaskRemoved() async => stop();

  Future<void> dispose() async => _player.dispose();
}