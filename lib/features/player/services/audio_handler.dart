// lib/features/player/services/audio_handler.dart
//
// MULTI-PART UNIFIED SEEKBAR + OFFLINE MULTI-PART FIX
// =====================================================
//
// OFFLINE MULTI-PART FIX (this change):
// When a downloaded multi-part episode is played offline, the Downloads
// screen sets:
//   item.extras['offlinePartUrls'] = 'file:///part0|file:///part1|...'
//   item.partCount = N
//   item.streamUrl = 'file:///part0'   (first part, for single-part fast path)
//
// _buildPartUrls() checks for 'offlinePartUrls' in extras FIRST, and if
// found, splits on '|' and returns all part URIs directly.
// This means the handler plays each part file independently through its
// existing multi-part sequential logic — preserving each file's own MP3
// headers, which fixes the Xing-frame mismatch that caused only part 1
// to play.
//
// ONLINE MULTI-PART (unchanged):
// For online items, _buildPartUrls() falls through to _urlService which
// generates the ?part=N network URLs as before.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import 'multi_part_url_service.dart';

class AudioCalmHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  // ── Primary player (always the currently-playing part) ──────────────────
  ja.AudioPlayer _player = ja.AudioPlayer();

  // ── Pre-load player (silently buffers the next part) ────────────────────
  ja.AudioPlayer _preloadPlayer = ja.AudioPlayer();

  final MultiPartUrlService _urlService = MultiPartUrlService(null);

  // ── Queue / navigation state ─────────────────────────────────────────────
  List<PlayableItem> _playableQueue = [];
  int _currentQueueIndex = 0;
  bool _shuffleMode = false;
  ja.LoopMode _loopMode = ja.LoopMode.off;

  // ── Multi-part state for the CURRENT item ────────────────────────────────
  List<String> _partUrls = [];
  int _currentPartIndex = 0;
  Duration _partOffset = Duration.zero;
  final List<Duration> _partDurations = [];
  Duration? _knownTotalDuration;

  // ── Subscriptions ─────────────────────────────────────────────────────────
  final List<StreamSubscription> _subs = [];
  StreamSubscription? _completionSub;

  AudioCalmHandler() {
    _init();
  }

  void _init() {
    _subs.add(_player.positionStream.listen((_) => _broadcastState()));
    _subs.add(_player.bufferedPositionStream.listen((_) => _broadcastState()));
    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      _broadcastState();
    }));
    _subs.add(_player.playerStateStream.listen((_) => _broadcastState()));
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
  //
  // Priority order:
  //   1. extras['offlinePartUrls']  — pipe-separated local file:// URIs
  //      (set by Downloads screen for offline multi-part playback)
  //   2. item.streamUrl starts with file:// or /
  //      (single-part offline, legacy path)
  //   3. Online: _urlService generates ?part=N network URLs

  List<String> _buildPartUrls(PlayableItem item) {
    // ── 1. Offline multi-part: read all part URIs from extras ─────────────
    final offlinePartUrls =
        item.extras['offlinePartUrls'] as String?;
    if (offlinePartUrls != null && offlinePartUrls.isNotEmpty) {
      final parts = offlinePartUrls
          .split('|')
          .where((s) => s.isNotEmpty)
          .toList();
      if (parts.isNotEmpty) {
        debugPrint(
            '[AudioHandler] Offline multi-part — ${parts.length} local URI(s)');
        return parts;
      }
    }

    // ── 2. Offline single-part: streamUrl is already a local path ─────────
    if (item.streamUrl.startsWith('file://') ||
        item.streamUrl.startsWith('/')) {
      debugPrint(
          '[AudioHandler] Offline single-part — URI: ${item.streamUrl}');
      return [item.streamUrl];
    }

    // ── 3. Online: build ?part=N network URLs ─────────────────────────────
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

  // ── Load a specific part and start playing ─────────────────────────────────

  Future<void> _loadPartAndPlay(int partIndex,
      {Duration startAt = Duration.zero}) async {
    _currentPartIndex = partIndex;

    while (_partDurations.length <= partIndex) {
      _partDurations.add(Duration.zero);
    }

    await _completionSub?.cancel();
    _completionSub = null;

    final url = _partUrls[partIndex];
    debugPrint(
        '[AudioHandler] Loading part ${partIndex + 1}/${_partUrls.length}: $url');

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

  // ── Part completion handler ────────────────────────────────────────────────

  void _onPartCompleted() {
    final nextPart = _currentPartIndex + 1;

    if (nextPart < _partUrls.length) {
      final completed = _partDurations.length > _currentPartIndex
          ? _partDurations[_currentPartIndex]
          : (_player.duration ?? Duration.zero);

      _partOffset += completed;
      debugPrint('[AudioHandler] Part ${_currentPartIndex + 1} done. '
          'Offset now: ${_partOffset.inSeconds}s. '
          'Loading part ${nextPart + 1}/${_partUrls.length}.');
      _loadPartAndPlay(nextPart);
    } else {
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
    debugPrint('[AudioHandler] Pre-loading part ${nextPart + 1}: $url');

    _preloadPlayer.dispose();
    _preloadPlayer = ja.AudioPlayer();

    _preloadPlayer
        .setAudioSource(ja.AudioSource.uri(Uri.parse(url)))
        .then((_) {
      _preloadReady = true;
      debugPrint('[AudioHandler] Pre-load ready for part ${nextPart + 1}');
    }).catchError((e) {
      _preloadReady = false;
      debugPrint(
          '[AudioHandler] Pre-load failed for part ${nextPart + 1}: $e');
    });
  }

  Future<void> _swapToPreloaded() async {
    debugPrint('[AudioHandler] Swapping to pre-loaded player.');

    await _completionSub?.cancel();
    _completionSub = null;

    final oldPlayer = _player;
    _player = _preloadPlayer;
    _preloadPlayer = ja.AudioPlayer();
    _preloadReady = false;

    _reAttachStreams();
    await _player.play();

    Future.delayed(const Duration(milliseconds: 500),
        () => oldPlayer.dispose());
  }

  void _reAttachStreams() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();

    _subs.add(_player.positionStream.listen((_) => _broadcastState()));
    _subs
        .add(_player.bufferedPositionStream.listen((_) => _broadcastState()));
    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      _broadcastState();
    }));
    _subs.add(_player.playerStateStream.listen((_) => _broadcastState()));
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
    _knownTotalDuration =
        item.duration != null ? Duration(seconds: item.duration!) : null;

    mediaItem.add(_playableToMediaItem(item));
    debugPrint('[AudioHandler] Loading "${item.title}" — '
        '${_partUrls.length} part(s), '
        'known total: ${_knownTotalDuration?.inSeconds}s, '
        'offline: ${item.extras['isOffline'] == true}');

    await _loadPartAndPlay(0);
  }

  MediaItem _playableToMediaItem(PlayableItem item) {
    return MediaItem(
      id: item.id,
      title: item.title,
      artist: item.subtitle,
      artUri:
          item.artworkUrl != null ? Uri.parse(item.artworkUrl!) : null,
      duration:
          item.duration != null ? Duration(seconds: item.duration!) : null,
      extras: {
        'type': item.type.name,
        'streamUrl': item.streamUrl,
        'partCount': item.partCount,
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
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
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
  }

  @override
  Future<void> skipToNext() async {
    if (_currentQueueIndex < _playableQueue.length - 1) {
      await _playItemAtQueueIndex(_currentQueueIndex + 1);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position.inSeconds > 3 || _partOffset.inSeconds > 0) {
      await _loadItem(_playableQueue[_currentQueueIndex]);
    } else if (_currentQueueIndex > 0) {
      await _playItemAtQueueIndex(_currentQueueIndex - 1);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _playItemAtQueueIndex(index);
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

  Future<void> seekForwardOnce() => seekForward(true);
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

  Stream<Duration> get positionStream =>
      _player.positionStream.map((_) => _unifiedPosition);
  Stream<Duration?> get durationStream =>
      _player.durationStream.map((_) => _unifiedDuration);
  Stream<ja.PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<double> get speedStream => _player.speedStream;

  Duration get position => _unifiedPosition;
  Duration? get duration => _unifiedDuration;
  bool get playing => _player.playing;
  double get speed => _player.speed;
  int get currentIndex => _currentQueueIndex;
  List<PlayableItem> get playableQueue => _playableQueue;
  ja.LoopMode get loopMode => _loopMode;
  bool get shuffleMode => _shuffleMode;

  // ── Broadcast state ────────────────────────────────────────────────────────

  void _broadcastState() {
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
        ja.ProcessingState.idle: AudioProcessingState.idle,
        ja.ProcessingState.loading: AudioProcessingState.loading,
        ja.ProcessingState.buffering: AudioProcessingState.buffering,
        ja.ProcessingState.ready: AudioProcessingState.ready,
        ja.ProcessingState.completed: AudioProcessingState.completed,
      }[ps]!,
      playing: isPlaying,
      updatePosition: _unifiedPosition,
      bufferedPosition: _partOffset + _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentQueueIndex,
    ));
  }

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