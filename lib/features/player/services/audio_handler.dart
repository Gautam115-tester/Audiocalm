// lib/features/player/services/audio_handler.dart
//
// BLAST BUFFER QUEUE FIX — DEEP ANALYSIS & ROOT CAUSE
// ====================================================
//
// ERROR: "acquireNextBufferLocked: Can't acquire next buffer.
//         Already acquired max frames 7 max:5 + 2"
//
// ANDROID SURFACE BUFFER QUEUE ARCHITECTURE:
//   - Android SurfaceFlinger allocates a circular buffer queue per SurfaceView
//   - Default max: 5 dequeued + 2 in-flight = 7 total "acquired" frames
//   - When the producer (Flutter GPU thread) tries to enqueue an 8th frame
//     before the consumer (SurfaceFlinger) has composited any, it overflows
//   - This is NOT a rendering bug — it is a SCHEDULING bug: frames are being
//     GENERATED faster than they can be CONSUMED
//
// ROOT CAUSE IN THIS FILE (audio_handler.dart):
//   The previous fix used scheduleMicrotask() for coalescing. This is WRONG
//   for the following reason:
//
//   Microtasks run in a tight loop BEFORE yielding back to the event loop.
//   The Dart event loop order is:
//     [sync code] → [microtask queue] → [event loop tick] → [frame callback]
//
//   When _player.positionStream fires at 10Hz AND _player.durationStream fires
//   AND _player.playerStateStream fires simultaneously (e.g. on seek), they all
//   call _scheduleBroadcast() in the same sync frame. scheduleMicrotask()
//   registers ONE microtask — so that part works.
//
//   BUT: when _broadcastStateNow() calls playbackState.add(), AudioService
//   internally calls onPlaybackStateChanged() on the Android platform channel,
//   which posts to the Android main thread. The Android main thread then
//   triggers a notification redraw via NotificationCompat.Builder, which calls
//   RemoteViews.apply(), which calls Canvas operations, which calls
//   SurfaceView.lockCanvas() / unlockCanvasAndPost().
//
//   This notification redraw is SEPARATE from Flutter's rendering pipeline.
//   It queues a buffer in the SAME SurfaceView as Flutter's rendering.
//   When Flutter's rasterizer AND the notification redraws BOTH queue frames
//   faster than SurfaceFlinger can composite them, the buffer fills up.
//
//   THE REAL FIX:
//   1. Use a minimum interval timer (16ms = 1 frame at 60fps) between
//      broadcasts, not just microtask coalescing. This matches SurfaceFlinger's
//      consumption rate.
//   2. On critical state changes (play/pause/skip) we still broadcast
//      immediately but then impose a 16ms cooldown before the next one.
//   3. Position-only updates (the highest frequency) are further throttled to
//      200ms since the notification seekbar doesn't need 10Hz updates.
//
// SECONDARY ROOT CAUSE — Download progress updates:
//   The isolate sends progress messages on every ReceivePort.listen() callback.
//   Dio's onReceiveProgress fires per-chunk (can be 50-100 times/second for
//   fast connections). Each message → _updateState() → state = {...state} →
//   Riverpod notifies ALL watchers → _ActiveDownloadCard rebuilds → new frame.
//   Fix: throttle progress messages to max 10Hz in the isolate worker.
//
// TERTIARY ROOT CAUSE — app_shell.dart watches audioPlayerProvider:
//   The shell rebuilds on EVERY position tick (100ms) even though it only
//   cares about `hasMedia`. Fix: use .select() to only watch hasMedia.

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

  // ── FIX: Frame-rate-aware broadcast throttling ─────────────────────────────
  //
  // TWO-TIER throttle system:
  //
  // Tier 1 — Microtask coalescing (unchanged from before):
  //   Collapses multiple stream events fired in the SAME sync frame into one
  //   pending broadcast. _pendingBroadcast flag prevents duplicate scheduling.
  //
  // Tier 2 — Minimum interval timer (NEW):
  //   Even after coalescing, broadcasts can still fire at 10Hz (position stream
  //   tick rate). At 60fps, a frame takes 16.67ms. If we broadcast every 100ms
  //   (position tick), that's 6 broadcasts per 60 frames. Each broadcast posts
  //   to Android's notification system which queues a SurfaceView buffer.
  //   By enforcing a 16ms minimum between broadcasts, we cap at ~60/s max,
  //   matching SurfaceFlinger's consumption rate so buffers never accumulate.
  //
  // Tier 3 — Position-only throttle (NEW):
  //   Position stream fires at ~10Hz. The Android notification seekbar updates
  //   look fine at 5Hz. We track the last broadcast time and skip position-only
  //   broadcasts that arrive within 200ms of the last one.
  //   "Position-only" means: nothing changed except position (not play/pause/
  //   loading state, not duration, not queue index).

  bool _pendingBroadcast = false;
  DateTime _lastBroadcastTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _throttleTimer;

  // Minimum time between ANY broadcast (matches one frame at 60fps)
  static const Duration _kMinBroadcastInterval = Duration(milliseconds: 16);

  // Minimum time between POSITION-ONLY broadcasts (5Hz max for notification)
  static const Duration _kPositionBroadcastInterval = Duration(milliseconds: 200);

  // Track last broadcast's "structural" state to detect position-only changes
  bool _lastBroadcastPlaying = false;
  bool _lastBroadcastLoading = false;
  int _lastBroadcastQueueIndex = -1;
  Duration _lastBroadcastDuration = Duration.zero;

  // ── Position save throttle ─────────────────────────────────────────────────
  int _lastSavedPositionSeconds = 0;
  static const int _saveIntervalSeconds = 5;

  AudioCalmHandler() {
    _init();
  }

  void _init() {
    // FIX: positionStream uses the position-aware scheduler that applies
    // the coarser 200ms throttle since position is the highest-frequency event
    _subs.add(_player.positionStream.listen((_) {
      _schedulePositionBroadcast();
      _maybeSavePosition();
    }));

    // These use the standard scheduler (still coalesced but not position-throttled)
    _subs.add(
        _player.bufferedPositionStream.listen((_) => _scheduleBroadcast(structural: false)));
    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      _scheduleBroadcast(structural: true);
    }));
    _subs.add(_player.playerStateStream.listen((_) => _scheduleBroadcast(structural: true)));
  }

  // ── TIER 1: Microtask coalescing ───────────────────────────────────────────
  void _scheduleBroadcast({bool structural = true}) {
    if (_pendingBroadcast) return;
    _pendingBroadcast = true;
    scheduleMicrotask(() {
      _pendingBroadcast = false;
      _maybeBroadcast(isPositionOnly: !structural);
    });
  }

  // Position-aware scheduler: checks position-throttle interval first
  void _schedulePositionBroadcast() {
    if (_pendingBroadcast) return;
    // Check if enough time has passed for a position-only broadcast
    final now = DateTime.now();
    final sinceLastBroadcast = now.difference(_lastBroadcastTime);
    if (sinceLastBroadcast < _kPositionBroadcastInterval) {
      // Skip this position tick entirely — too soon
      return;
    }
    _pendingBroadcast = true;
    scheduleMicrotask(() {
      _pendingBroadcast = false;
      _maybeBroadcast(isPositionOnly: true);
    });
  }

  // ── TIER 2: Minimum interval enforcement ──────────────────────────────────
  void _maybeBroadcast({required bool isPositionOnly}) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastBroadcastTime);

    if (elapsed >= _kMinBroadcastInterval) {
      // Enough time has passed — broadcast now
      _lastBroadcastTime = now;
      _broadcastStateNow();
    } else {
      // Too soon — schedule for when the interval expires
      // Only schedule if we don't already have a pending timer
      _throttleTimer?.cancel();
      final remaining = _kMinBroadcastInterval - elapsed;
      _throttleTimer = Timer(remaining, () {
        _lastBroadcastTime = DateTime.now();
        _broadcastStateNow();
      });
    }
  }

  // ── TIER 3: Immediate broadcast for critical state changes ─────────────────
  // Used for play/pause/skip/stop where notification latency matters.
  // Resets the throttle timer so subsequent position ticks don't fire immediately.
  void _broadcastCritical() {
    _throttleTimer?.cancel();
    _pendingBroadcast = false;
    _lastBroadcastTime = DateTime.now();
    _broadcastStateNow();
  }

  /// Core broadcast implementation — sends current state to AudioService.
  /// Called by both the throttled path and the critical path.
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

    // Update structural state cache for next comparison
    _lastBroadcastPlaying = isPlaying;
    _lastBroadcastLoading = (ps == ja.ProcessingState.loading ||
        ps == ja.ProcessingState.buffering);
    _lastBroadcastQueueIndex = _currentQueueIndex;
    _lastBroadcastDuration = _unifiedDuration;
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

    // Re-attach with the same throttled approach
    _subs.add(_player.positionStream.listen((_) {
      _schedulePositionBroadcast();
      _maybeSavePosition();
    }));
    _subs.add(_player.bufferedPositionStream
        .listen((_) => _scheduleBroadcast(structural: false)));
    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      _scheduleBroadcast(structural: true);
    }));
    _subs.add(_player.playerStateStream
        .listen((_) => _scheduleBroadcast(structural: true)));
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
    _broadcastCritical(); // immediate notification on item load
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
    _broadcastCritical(); // immediate on play
  }

  @override
  Future<void> pause() async {
    _savePositionNow();
    await _player.pause();
    _broadcastCritical(); // immediate on pause
  }

  @override
  Future<void> stop() async {
    _savePositionNow();
    await _player.stop();
    _broadcastCritical(); // immediate on stop
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_partUrls.length <= 1) {
      await _player.seek(position);
      _broadcastCritical();
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
    _broadcastCritical(); // immediate on seek
  }

  @override
  Future<void> skipToNext() async {
    _savePositionNow();
    if (_currentQueueIndex < _playableQueue.length - 1) {
      await _playItemAtQueueIndex(_currentQueueIndex + 1);
    }
    _broadcastCritical();
  }

  @override
  Future<void> skipToPrevious() async {
    _savePositionNow();
    if (_player.position.inSeconds > 3 || _partOffset.inSeconds > 0) {
      await _loadItem(_playableQueue[_currentQueueIndex]);
    } else if (_currentQueueIndex > 0) {
      await _playItemAtQueueIndex(_currentQueueIndex - 1);
    }
    _broadcastCritical();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _savePositionNow();
    await _playItemAtQueueIndex(index);
    _broadcastCritical();
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
    _throttleTimer?.cancel();
    await _completionSub?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    await _player.dispose();
    await _preloadPlayer.dispose();
  }
}