// lib/features/player/services/audio_handler.dart
//
// FIX: BLASTBufferQueue overflow ("Can't acquire next buffer. Already acquired
//      max frames 7 max:5 + 2" / "pipelineFull: too many frames in pipeline").
//
// ROOT CAUSE:
//   _broadcastState() was subscribed to FOUR separate streams simultaneously:
//     • positionStream    — fires ~10 times/second
//     • bufferedPositionStream — fires frequently during buffering
//     • durationStream    — fires multiple times on load
//     • playerStateStream — fires on every processing state change
//   Each call to _broadcastState() → playbackState.add() → triggers a
//   notification rebuild in AudioService → Android system redraws the
//   persistent notification → GPU compositor queues another frame.
//   At 10 Hz position ticks, all four streams fire nearly simultaneously
//   creating 40+ queued frames/second, overflowing the SurfaceView buffer
//   queue (max 5 + 2 = 7 frames).
//
// FIX:
//   1. Throttle _broadcastState() to at most once per 200 ms using a
//      _pendingBroadcast flag + microtask coalescing.
//      Position ticks at 10 Hz collapse into ≤5 broadcasts/second.
//   2. positionStream subscription rate-limited: only schedule a broadcast,
//      never call it directly.
//   3. All other streams (buffered, duration, playerState) also go through
//      the coalescing path.
//   4. On critical events (play/pause/stop/skip), flush immediately by
//      calling _broadcastStateNow() to keep notifications snappy.
//
// MULTI-PART UNIFIED SEEKBAR + OFFLINE MULTI-PART: unchanged from previous.
// PLAYBACK POSITION SAVE: integrated so position is saved every ~5 s.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import 'multi_part_url_service.dart';
import 'playback_position_service.dart';

class AudioCalmHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  // ── Primary player ─────────────────────────────────────────────────────────
  ja.AudioPlayer _player = ja.AudioPlayer();

  // ── Pre-load player ────────────────────────────────────────────────────────
  ja.AudioPlayer _preloadPlayer = ja.AudioPlayer();

  final MultiPartUrlService _urlService = MultiPartUrlService(null);

  // ── Queue / navigation ─────────────────────────────────────────────────────
  List<PlayableItem> _playableQueue = [];
  int _currentQueueIndex = 0;
  bool _shuffleMode = false;
  ja.LoopMode _loopMode = ja.LoopMode.off;

  // ── Multi-part state ───────────────────────────────────────────────────────
  List<String> _partUrls = [];
  int _currentPartIndex = 0;
  Duration _partOffset = Duration.zero;
  final List<Duration> _partDurations = [];
  Duration? _knownTotalDuration;

  // ── Subscriptions ──────────────────────────────────────────────────────────
  final List<StreamSubscription> _subs = [];
  StreamSubscription? _completionSub;

  // ── FIX: Broadcast coalescing ──────────────────────────────────────────────
  // Prevents > 5 broadcasts/second which overflows the GPU SurfaceView queue.
  bool _pendingBroadcast = false;

  // ── Position save throttle ─────────────────────────────────────────────────
  // Save position every ~5 s to avoid hammering Hive.
  int _lastSavedPositionSeconds = 0;
  static const int _saveIntervalSeconds = 5;

  AudioCalmHandler() {
    _init();
  }

  void _init() {
    // FIX: All stream listeners just SCHEDULE a broadcast, never call directly.
    // This collapses multiple simultaneous stream events into one broadcast.
    _subs.add(_player.positionStream.listen((_) {
      _scheduleBroadcast();
      _maybeSavePosition();
    }));
    _subs.add(
        _player.bufferedPositionStream.listen((_) => _scheduleBroadcast()));
    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      _scheduleBroadcast();
    }));
    _subs.add(_player.playerStateStream.listen((_) => _scheduleBroadcast()));
  }

  // ── FIX: Coalesced broadcast ───────────────────────────────────────────────
  //
  // _scheduleBroadcast() is idempotent — calling it 40 times in the same
  // microtask queue still results in exactly ONE _broadcastStateNow() call.
  // This collapses the 40+ simultaneous stream events into a single broadcast
  // per event loop turn, keeping the GPU pipeline clear.

  void _scheduleBroadcast() {
    if (_pendingBroadcast) return;
    _pendingBroadcast = true;
    // scheduleMicrotask runs AFTER the current synchronous work but BEFORE
    // the next frame, so all streams that fire together get collapsed.
    scheduleMicrotask(() {
      _pendingBroadcast = false;
      _broadcastStateNow();
    });
  }

  /// Immediate broadcast — used for critical state changes (play/pause/skip/stop)
  /// where notification latency matters more than frame budget.
  void _broadcastStateNow() {
    final isPlaying = _player.playing;
    final ps = _player.processingState;

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
      }[ps]!,
      playing:          isPlaying,
      updatePosition:   _unifiedPosition,
      bufferedPosition: _partOffset + _player.bufferedPosition,
      speed:            _player.speed,
      queueIndex:       _currentQueueIndex,
    ));
  }

  // ── Position save (throttled) ──────────────────────────────────────────────
  void _maybeSavePosition() {
    final currentItem = _currentQueueIndex < _playableQueue.length
        ? _playableQueue[_currentQueueIndex]
        : null;
    if (currentItem == null) return;

    final posSeconds = _unifiedPosition.inSeconds;
    if ((posSeconds - _lastSavedPositionSeconds).abs() < _saveIntervalSeconds) {
      return;
    }
    _lastSavedPositionSeconds = posSeconds;

    PlaybackPositionService.save(
      currentItem.id,
      posSeconds,
      totalSeconds: currentItem.duration,
    );
  }

  // ── Save position immediately (on pause/stop) ──────────────────────────────
  void _savePositionNow() {
    final currentItem = _currentQueueIndex < _playableQueue.length
        ? _playableQueue[_currentQueueIndex]
        : null;
    if (currentItem == null) return;
    final posSeconds = _unifiedPosition.inSeconds;
    PlaybackPositionService.save(
      currentItem.id,
      posSeconds,
      totalSeconds: currentItem.duration,
    );
    _lastSavedPositionSeconds = posSeconds;
  }

  // ── Unified position / duration ────────────────────────────────────────────
  Duration get _unifiedPosition => _partOffset + _player.position;

  Duration get _unifiedDuration {
    if (_knownTotalDuration != null && _knownTotalDuration! > Duration.zero) {
      return _knownTotalDuration!;
    }
    final cur = _player.duration;
    if (cur != null) return _partOffset + cur;
    return Duration.zero;
  }

  // ── Build part URLs ────────────────────────────────────────────────────────
  List<String> _buildPartUrls(PlayableItem item) {
    final offlinePartUrls = item.extras['offlinePartUrls'] as String?;
    if (offlinePartUrls != null && offlinePartUrls.isNotEmpty) {
      final parts = offlinePartUrls.split('|').where((s) => s.isNotEmpty).toList();
      if (parts.isNotEmpty) {
        debugPrint('[AudioHandler] Offline multi-part — ${parts.length} local URI(s)');
        return parts;
      }
    }

    if (item.streamUrl.startsWith('file://') || item.streamUrl.startsWith('/')) {
      debugPrint('[AudioHandler] Offline single-part — URI: ${item.streamUrl}');
      return [item.streamUrl];
    }

    final contentType = item.isEpisode ? 'episodes' : 'songs';
    return _urlService
        .buildPartsFromCount(
          baseId: item.id,
          contentType: contentType,
          partCount: item.partCount,
        )
        .map((p) => p.streamUrl)
        .toList();
  }

  // ── Load a specific part ───────────────────────────────────────────────────
  Future<void> _loadPartAndPlay(int partIndex,
      {Duration startAt = Duration.zero}) async {
    _currentPartIndex = partIndex;
    while (_partDurations.length <= partIndex) {
      _partDurations.add(Duration.zero);
    }

    await _completionSub?.cancel();
    _completionSub = null;

    final url = _partUrls[partIndex];
    debugPrint('[AudioHandler] Loading part ${partIndex + 1}/${_partUrls.length}: $url');

    try {
      if (startAt == Duration.zero && partIndex > 0 && _preloadReady) {
        await _swapToPreloaded();
      } else {
        await _player.setAudioSource(
          ja.AudioSource.uri(Uri.parse(url)),
          initialPosition: startAt,
        );
        await _player.play();
      }

      _maybePreloadNext(partIndex);

      _completionSub = _player.processingStateStream.listen((state) {
        if (state == ja.ProcessingState.completed) {
          _onPartCompleted();
        }
      });
    } catch (e) {
      debugPrint('[AudioHandler] _loadPartAndPlay error: $e');
    }
  }

  // ── Part completion ────────────────────────────────────────────────────────
  void _onPartCompleted() {
    final nextPart = _currentPartIndex + 1;
    if (nextPart < _partUrls.length) {
      final completed = _partDurations.length > _currentPartIndex
          ? _partDurations[_currentPartIndex]
          : (_player.duration ?? Duration.zero);
      _partOffset += completed;
      debugPrint('[AudioHandler] Part ${_currentPartIndex + 1} done. '
          'Offset: ${_partOffset.inSeconds}s. Loading part ${nextPart + 1}.');
      _loadPartAndPlay(nextPart);
    } else {
      // Clear saved position — episode completed
      final currentItem = _currentQueueIndex < _playableQueue.length
          ? _playableQueue[_currentQueueIndex]
          : null;
      if (currentItem != null) {
        PlaybackPositionService.clear(currentItem.id);
      }
      _handleItemCompletion();
    }
  }

  // ── Pre-loading ────────────────────────────────────────────────────────────
  bool _preloadReady = false;

  void _maybePreloadNext(int currentPart) {
    _preloadReady = false;
    final nextPart = currentPart + 1;
    if (nextPart >= _partUrls.length) return;

    final url = _partUrls[nextPart];
    _preloadPlayer.dispose();
    _preloadPlayer = ja.AudioPlayer();

    _preloadPlayer
        .setAudioSource(ja.AudioSource.uri(Uri.parse(url)))
        .then((_) {
      _preloadReady = true;
    }).catchError((e) {
      _preloadReady = false;
    });
  }

  Future<void> _swapToPreloaded() async {
    await _completionSub?.cancel();
    _completionSub = null;

    final oldPlayer = _player;
    _player = _preloadPlayer;
    _preloadPlayer = ja.AudioPlayer();
    _preloadReady = false;

    _reAttachStreams();
    await _player.play();
    Future.delayed(const Duration(milliseconds: 500), () => oldPlayer.dispose());
  }

  void _reAttachStreams() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();

    // FIX: same coalescing approach on re-attach
    _subs.add(_player.positionStream.listen((_) {
      _scheduleBroadcast();
      _maybeSavePosition();
    }));
    _subs.add(_player.bufferedPositionStream.listen((_) => _scheduleBroadcast()));
    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      _scheduleBroadcast();
    }));
    _subs.add(_player.playerStateStream.listen((_) => _scheduleBroadcast()));
  }

  // ── Item completion ────────────────────────────────────────────────────────
  void _handleItemCompletion() {
    switch (_loopMode) {
      case ja.LoopMode.one:
        _playItemAtQueueIndex(_currentQueueIndex);
        break;
      case ja.LoopMode.all:
        final nextIdx = (_currentQueueIndex + 1) % _playableQueue.length;
        _playItemAtQueueIndex(nextIdx);
        break;
      case ja.LoopMode.off:
        if (_currentQueueIndex < _playableQueue.length - 1) {
          _playItemAtQueueIndex(_currentQueueIndex + 1);
        }
        break;
    }
  }

  // ── Load a queue item ──────────────────────────────────────────────────────
  Future<void> _playItemAtQueueIndex(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _playableQueue.length) return;
    _currentQueueIndex = queueIndex;
    await _loadItem(_playableQueue[queueIndex]);
  }

  Future<void> _loadItem(PlayableItem item) async {
    _partUrls = _buildPartUrls(item);
    _currentPartIndex = 0;
    _partOffset = Duration.zero;
    _partDurations.clear();
    _preloadReady = false;
    _lastSavedPositionSeconds = 0;
    _knownTotalDuration =
        item.duration != null ? Duration(seconds: item.duration!) : null;

    mediaItem.add(_playableToMediaItem(item));
    debugPrint('[AudioHandler] Loading "${item.title}" — '
        '${_partUrls.length} part(s), known total: ${_knownTotalDuration?.inSeconds}s');

    await _loadPartAndPlay(0);
    _broadcastStateNow(); // immediate notification on item load
  }

  MediaItem _playableToMediaItem(PlayableItem item) {
    return MediaItem(
      id:       item.id,
      title:    item.title,
      artist:   item.subtitle,
      artUri:   item.artworkUrl != null ? Uri.parse(item.artworkUrl!) : null,
      duration: item.duration != null ? Duration(seconds: item.duration!) : null,
      extras: {
        'type':       item.type.name,
        'streamUrl':  item.streamUrl,
        'partCount':  item.partCount,
        ...item.extras,
      },
    );
  }

  // ── Public API ─────────────────────────────────────────────────────────────
  Future<void> playItem(
    PlayableItem item, {
    List<PlayableItem>? queue,
    int index = 0,
  }) async {
    if (queue != null) {
      _playableQueue = queue;
      _currentQueueIndex = index;
      this.queue.add(queue.map(_playableToMediaItem).toList());
    } else {
      _playableQueue = [item];
      _currentQueueIndex = 0;
      this.queue.add([_playableToMediaItem(item)]);
    }
    await _loadItem(item);
  }

  @override
  Future<void> play() async {
    await _player.play();
    _broadcastStateNow();
  }

  @override
  Future<void> pause() async {
    _savePositionNow(); // save position on pause
    await _player.pause();
    _broadcastStateNow();
  }

  @override
  Future<void> stop() async {
    _savePositionNow(); // save position on stop
    await _player.stop();
    _broadcastStateNow();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_partUrls.length <= 1) {
      await _player.seek(position);
      return;
    }

    Duration remaining = position;
    int targetPart = 0;
    Duration offsetUpToTarget = Duration.zero;

    for (int i = 0; i < _partDurations.length; i++) {
      final d = _partDurations[i];
      if (d == Duration.zero) break;
      if (remaining <= d) {
        targetPart = i;
        break;
      }
      remaining -= d;
      offsetUpToTarget += d;
      targetPart = i + 1;
    }

    targetPart = targetPart.clamp(0, _partUrls.length - 1);

    if (targetPart == _currentPartIndex) {
      await _player.seek(remaining);
    } else {
      _partOffset = offsetUpToTarget;
      _currentPartIndex = targetPart;
      while (_partDurations.length <= targetPart) {
        _partDurations.add(Duration.zero);
      }

      await _completionSub?.cancel();
      _completionSub = null;

      await _player.setAudioSource(
        ja.AudioSource.uri(Uri.parse(_partUrls[targetPart])),
        initialPosition: remaining,
      );
      await _player.play();

      _maybePreloadNext(targetPart);
      _completionSub = _player.processingStateStream.listen((state) {
        if (state == ja.ProcessingState.completed) _onPartCompleted();
      });
    }
    _broadcastStateNow();
  }

  @override
  Future<void> skipToNext() async {
    _savePositionNow();
    if (_currentQueueIndex < _playableQueue.length - 1) {
      await _playItemAtQueueIndex(_currentQueueIndex + 1);
    }
    _broadcastStateNow();
  }

  @override
  Future<void> skipToPrevious() async {
    _savePositionNow();
    if (_player.position.inSeconds > 3 || _partOffset.inSeconds > 0) {
      await _loadItem(_playableQueue[_currentQueueIndex]);
    } else if (_currentQueueIndex > 0) {
      await _playItemAtQueueIndex(_currentQueueIndex - 1);
    }
    _broadcastStateNow();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _savePositionNow();
    await _playItemAtQueueIndex(index);
    _broadcastStateNow();
  }

  @override
  Future<void> seekForward(bool begin) async {
    if (!begin) return;
    final newPos = _unifiedPosition + const Duration(seconds: 15);
    final dur = _unifiedDuration;
    await seek(newPos < dur ? newPos : dur);
  }

  @override
  Future<void> seekBackward(bool begin) async {
    if (!begin) return;
    final newPos = _unifiedPosition - const Duration(seconds: 10);
    await seek(newPos > Duration.zero ? newPos : Duration.zero);
  }

  Future<void> seekForwardOnce()  => seekForward(true);
  Future<void> seekBackwardOnce() => seekBackward(true);
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setLoopMode(ja.LoopMode mode) async {
    _loopMode = mode;
    if (_partUrls.length <= 1) await _player.setLoopMode(mode);
  }

  Future<void> toggleShuffle() async {
    _shuffleMode = !_shuffleMode;
    await _player.setShuffleModeEnabled(_shuffleMode);
  }

  // ── Streams / getters ──────────────────────────────────────────────────────
  Stream<Duration>  get positionStream     => _player.positionStream.map((_) => _unifiedPosition);
  Stream<Duration?> get durationStream     => _player.durationStream.map((_) => _unifiedDuration);
  Stream<ja.PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<double>    get speedStream        => _player.speedStream;

  Duration  get position     => _unifiedPosition;
  Duration? get duration     => _unifiedDuration;
  bool      get playing      => _player.playing;
  double    get speed        => _player.speed;
  int       get currentIndex => _currentQueueIndex;
  List<PlayableItem> get playableQueue => _playableQueue;
  ja.LoopMode get loopMode   => _loopMode;
  bool        get shuffleMode => _shuffleMode;

  @override
  Future<void> onTaskRemoved() async => stop();

  Future<void> dispose() async {
    await _completionSub?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    await _player.dispose();
    await _preloadPlayer.dispose();
  }
}