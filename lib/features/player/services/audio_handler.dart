// lib/features/player/services/audio_handler.dart
//
// CHANGES IN THIS VERSION
// =======================
//
// NEXT-ITEM PRE-LOADING (gapless / seamless track transitions)
// -------------------------------------------------------------
// Problem: when a track ends, the next one starts loading from scratch —
// causing a 1-3 second gap (network round-trip + buffer fill) that interrupts
// the listening experience.
//
// Fix: 30 seconds before the current item ends, quietly open the next queue
// item's first audio part in a background player (`_nextItemPlayer`).
// When the current item actually finishes, we swap the pre-loaded player
// into the active slot instead of starting a fresh download.
//
// How it works:
//   1. `_scheduleNextItemPreload()` is called whenever a new item starts.
//      It reads the known total duration (or waits for just_audio to report it)
//      and sets a Timer to fire 30 s before the end.
//   2. When the timer fires, `_preloadNextQueueItem()` resolves the next
//      item's first-part URL and calls `_nextItemPlayer.setAudioSource()`
//      WITHOUT calling play() — this fills the network/decoder buffer silently.
//   3. When `_handleItemCompletion()` is called for a loopMode.off track:
//      - If `_nextItemPreloaded` is true, we swap `_nextItemPlayer` →
//        `_player`, re-attach streams, call play(), and start a new
//        preload cycle for the item after that.
//      - Otherwise (preload wasn't ready or timed out), we fall through to
//        the existing `_loadItem()` path unchanged.
//
// The preload is best-effort: if the timer fires and the next URL cannot
// be resolved, or if the user skips before the transition, we cancel
// cleanly and fall back to the normal loading path.  The listening
// experience degrades gracefully to the previous behaviour.
//
// Edge cases handled:
//   • User skips forward/backward: `_cancelNextItemPreload()` is called at
//     the top of `skipToNext` / `skipToPrevious` / `skipToQueueItem`.
//   • Last item in queue: no preload is attempted.
//   • Multi-part items: we only preload the first part of the next item
//     (same as what `_loadItem` does — the rest are loaded on demand).
//   • Loop modes: preload is skipped when loopMode == one (replays same item)
//     and handled for loopMode == all (wraps to index 0).
//   • Offline items: the URL is a local file:// URI — setAudioSource is fast
//     and essentially free, but we still preload to ensure the decoder is warm.
//
// ALL pre-existing logic (throttled broadcasts, multi-part streaming,
// part preloading within an item, position saving, seek) is unchanged.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import 'multi_part_url_service.dart';
import 'playback_position_service.dart';

class AudioCalmHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  // ── Stable broadcast streams ───────────────────────────────────────────────
  // These never change reference even when _player is swapped (gapless).
  // AudioPlayerNotifier subscribes ONCE to these; _reAttachStreams() re-pipes
  // events from whichever _player is current so the UI never goes stale.
  final _positionController    = StreamController<Duration>.broadcast();
  final _durationController    = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<ja.PlayerState>.broadcast();

  // ── Primary player ─────────────────────────────────────────────────────────
  ja.AudioPlayer _player = ja.AudioPlayer();

  // ── Within-item pre-load player (next PART of the same item) ──────────────
  ja.AudioPlayer _preloadPlayer = ja.AudioPlayer();

  // ── Next-item pre-load player (first part of the NEXT queue item) ─────────
  ja.AudioPlayer _nextItemPlayer = ja.AudioPlayer();
  bool _nextItemPreloaded = false;
  int _nextItemPreloadIndex = -1; // which queue index we preloaded
  Timer? _nextItemPreloadTimer;

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

  // ── Broadcast throttling (unchanged) ──────────────────────────────────────
  bool _pendingBroadcast = false;
  DateTime _lastBroadcastTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _throttleTimer;
  static const Duration _kMinBroadcastInterval = Duration(milliseconds: 16);
  static const Duration _kPositionBroadcastInterval = Duration(milliseconds: 200);
  bool _lastBroadcastPlaying = false;
  bool _lastBroadcastLoading = false;
  int _lastBroadcastQueueIndex = -1;
  Duration _lastBroadcastDuration = Duration.zero;

  // ── Position save throttle ─────────────────────────────────────────────────
  int _lastSavedPositionSeconds = 0;
  static const int _saveIntervalSeconds = 5;

  // ── Pre-load trigger: how many seconds before end to start next-item load ──
  static const int _kPreloadLeadSeconds = 30;

  AudioCalmHandler() {
    _init();
  }

  void _init() {
    // Delegate to _reAttachStreams so the stable controllers are wired up
    // immediately — and every future player swap re-calls this same method.
    _reAttachStreams();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // NEXT-ITEM PRE-LOADING
  // ═══════════════════════════════════════════════════════════════════════════

  /// Called whenever we start playing a new queue item.
  /// Sets a timer to preload the next item ~30 s before the end.
  void _scheduleNextItemPreload() {
    _cancelNextItemPreload();

    // Don't preload when looping a single track.
    if (_loopMode == ja.LoopMode.one) return;

    final nextIndex = _nextQueueIndex();
    if (nextIndex == null) return; // last item, no next

    final totalDuration = _knownTotalDuration;
    if (totalDuration == null || totalDuration == Duration.zero) {
      // Duration not yet known — _maybeReschedulePreloadTimer() will retry
      // once just_audio reports it via durationStream.
      return;
    }

    final leadTime = const Duration(seconds: _kPreloadLeadSeconds);
    final fireAfter = totalDuration - leadTime;
    if (fireAfter <= Duration.zero) {
      // Short track — preload immediately.
      _preloadNextQueueItem(nextIndex);
      return;
    }

    final currentPos = _unifiedPosition;
    final remaining = fireAfter - currentPos;
    if (remaining <= Duration.zero) {
      _preloadNextQueueItem(nextIndex);
      return;
    }

    _nextItemPreloadTimer = Timer(remaining, () {
      final idx = _nextQueueIndex();
      if (idx != null) _preloadNextQueueItem(idx);
    });
    debugPrint('[AudioHandler] Next-item preload scheduled in '
        '${remaining.inSeconds}s for queue[$nextIndex]');
  }

  /// Reschedule when duration becomes known after item load.
  void _maybeReschedulePreloadTimer() {
    if (_nextItemPreloadTimer != null) return; // already scheduled
    if (_nextItemPreloaded) return; // already done
    _scheduleNextItemPreload();
  }

  /// Cancel any pending next-item preload (e.g. on skip).
  /// NOTIFICATION FIX: We NO LONGER dispose+recreate _nextItemPlayer here.
  /// Repeated dispose() calls on AudioPlayer accumulate Android MediaSession
  /// state changes that confuse audio_service and eventually kill the
  /// foreground service notification. Instead we just stop the player and
  /// clear its source — reuse the same instance across cancellations.
  void _cancelNextItemPreload() {
    _nextItemPreloadTimer?.cancel();
    _nextItemPreloadTimer = null;
    _nextItemPreloaded = false;
    _nextItemPreloadIndex = -1;
    // Stop silently — do NOT dispose. Reuse the player for the next preload.
    _nextItemPlayer.stop().catchError((_) {});
  }

  /// Silently load the first part of queue item at [index] into the
  /// background player.  Does NOT call play().
  Future<void> _preloadNextQueueItem(int index) async {
    if (index < 0 || index >= _playableQueue.length) return;
    final item = _playableQueue[index];
    final urls = _buildPartUrls(item);
    if (urls.isEmpty) return;

    try {
      debugPrint('[AudioHandler] Preloading queue[$index] "${item.title}"');
      await _nextItemPlayer.setAudioSource(
        ja.AudioSource.uri(Uri.parse(urls.first)),
        preload: true,
      );
      _nextItemPreloaded = true;
      _nextItemPreloadIndex = index;
      debugPrint('[AudioHandler] Preload ready for queue[$index]');
    } catch (e) {
      debugPrint('[AudioHandler] Preload failed for queue[$index]: $e');
      _nextItemPreloaded = false;
    }
  }

  /// Returns the queue index that should play after the current item,
  /// accounting for loop mode.  Returns null if there is no next item.
  int? _nextQueueIndex() {
    if (_playableQueue.isEmpty) return null;
    switch (_loopMode) {
      case ja.LoopMode.one:
        return null; // replays same item — no "next"
      case ja.LoopMode.all:
        return (_currentQueueIndex + 1) % _playableQueue.length;
      case ja.LoopMode.off:
        final next = _currentQueueIndex + 1;
        return next < _playableQueue.length ? next : null;
    }
  }

  // ── Swap pre-loaded next-item player into the active slot ──────────────────
  Future<void> _swapToNextItemPlayer(int nextQueueIndex) async {
    debugPrint('[AudioHandler] Swapping to pre-loaded queue[$nextQueueIndex]');

    await _completionSub?.cancel();
    _completionSub = null;

    // Promote the pre-loaded player to primary.
    final oldPlayer = _player;
    _player = _nextItemPlayer;
    // NOTIFICATION FIX: Don't dispose+recreate here. Create a fresh player
    // for future preloads without the overhead of dispose (which triggers
    // Android MediaSession state changes that accumulate and kill the
    // foreground notification after several tracks).
    _nextItemPlayer = ja.AudioPlayer();
    _nextItemPreloaded = false;
    _nextItemPreloadIndex = -1;

    // Reset multi-part state for the new item.
    final item = _playableQueue[nextQueueIndex];
    _currentQueueIndex = nextQueueIndex;
    _partUrls = _buildPartUrls(item);
    _currentPartIndex = 0;
    _partOffset = Duration.zero;
    _partDurations.clear();
    _lastSavedPositionSeconds = 0;
    _knownTotalDuration =
        item.duration != null ? Duration(seconds: item.duration!) : null;

    mediaItem.add(_playableToMediaItem(item));
    _reAttachStreams();

    // Start playing immediately (the audio is already buffered).
    await _player.play();

    // Set up part-completion listener.
    _completionSub = _player.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed) _onPartCompleted();
    });

    _broadcastCritical();

    // Dispose old player after a short delay to avoid any in-flight reads.
    Future.delayed(const Duration(milliseconds: 500), () => oldPlayer.dispose());

    // Schedule the NEXT preload for the item after this one.
    _scheduleNextItemPreload();

    debugPrint('[AudioHandler] Gapless swap complete for "${item.title}"');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BROADCAST THROTTLING (unchanged)
  // ═══════════════════════════════════════════════════════════════════════════

  void _scheduleBroadcast({bool structural = true}) {
    if (_pendingBroadcast) return;
    _pendingBroadcast = true;
    scheduleMicrotask(() {
      _pendingBroadcast = false;
      _maybeBroadcast(isPositionOnly: !structural);
    });
  }

  void _schedulePositionBroadcast() {
    if (_pendingBroadcast) return;
    final now = DateTime.now();
    if (now.difference(_lastBroadcastTime) < _kPositionBroadcastInterval) return;
    _pendingBroadcast = true;
    scheduleMicrotask(() {
      _pendingBroadcast = false;
      _maybeBroadcast(isPositionOnly: true);
    });
  }

  void _maybeBroadcast({required bool isPositionOnly}) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastBroadcastTime);
    if (elapsed >= _kMinBroadcastInterval) {
      _lastBroadcastTime = now;
      _broadcastStateNow();
    } else {
      _throttleTimer?.cancel();
      final remaining = _kMinBroadcastInterval - elapsed;
      _throttleTimer = Timer(remaining, () {
        _lastBroadcastTime = DateTime.now();
        _broadcastStateNow();
      });
    }
  }

  void _broadcastCritical() {
    _throttleTimer?.cancel();
    _pendingBroadcast = false;
    _lastBroadcastTime = DateTime.now();
    _broadcastStateNow();
  }

  void _broadcastStateNow() {
    final isPlaying = _player.playing;
    final ps = _player.processingState;

    // NOTIFICATION FIX: Never send AudioProcessingState.completed upward to
    // audio_service. When 'completed' is broadcast, audio_service interprets
    // it as "session ended" and stops the foreground service — killing the
    // notification. _handleItemCompletion() immediately starts the next track,
    // so mapping completed→ready here is correct: we are still in an active
    // session. The actual "nothing more to play" case (last track, no loop)
    // just leaves the player idle, which maps to idle below.
    final mappedState = switch (ps) {
      ja.ProcessingState.idle      => AudioProcessingState.idle,
      ja.ProcessingState.loading   => AudioProcessingState.loading,
      ja.ProcessingState.buffering => AudioProcessingState.buffering,
      ja.ProcessingState.ready     => AudioProcessingState.ready,
      // Map completed → ready so audio_service never stops the foreground
      // service between tracks.
      ja.ProcessingState.completed => AudioProcessingState.ready,
    };

    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      // NOTIFICATION FIX: Remove seekForward / seekBackward from systemActions.
      // These tell Android to show rewind/fast-forward arrows in the
      // notification instead of clean prev/next/play controls.
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState:  mappedState,
      playing:          isPlaying,
      updatePosition:   _unifiedPosition,
      bufferedPosition: _partOffset + _player.bufferedPosition,
      speed:            _player.speed,
      queueIndex:       _currentQueueIndex,
    ));
    _lastBroadcastPlaying    = isPlaying;
    _lastBroadcastLoading    = (ps == ja.ProcessingState.loading ||
        ps == ja.ProcessingState.buffering);
    _lastBroadcastQueueIndex = _currentQueueIndex;
    _lastBroadcastDuration   = _unifiedDuration;
  }

  // ── Position save ──────────────────────────────────────────────────────────
  void _maybeSavePosition() {
    final currentItem = _currentQueueIndex < _playableQueue.length
        ? _playableQueue[_currentQueueIndex]
        : null;
    if (currentItem == null) return;
    final posSeconds = _unifiedPosition.inSeconds;
    if ((posSeconds - _lastSavedPositionSeconds).abs() < _saveIntervalSeconds) return;
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

      _maybePreloadNextPart(partIndex);

      _completionSub = _player.processingStateStream.listen((state) {
        if (state == ja.ProcessingState.completed) _onPartCompleted();
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
      if (currentItem != null) PlaybackPositionService.clear(currentItem.id);
      _handleItemCompletion();
    }
  }

  // ── Within-item part preloading ────────────────────────────────────────────
  bool _preloadReady = false;

  void _maybePreloadNextPart(int currentPart) {
    _preloadReady = false;
    final nextPart = currentPart + 1;
    if (nextPart >= _partUrls.length) return;

    final url = _partUrls[nextPart];
    // NOTIFICATION FIX: stop() instead of dispose()+recreate to avoid
    // accumulating Android MediaSession state changes that kill the notification.
    _preloadPlayer.stop().catchError((_) {});

    _preloadPlayer
        .setAudioSource(ja.AudioSource.uri(Uri.parse(url)))
        .then((_) { _preloadReady = true; })
        .catchError((e) { _preloadReady = false; });
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
    for (final s in _subs) { s.cancel(); }
    _subs.clear();

    // Position → stable controller + internal side-effects
    _subs.add(_player.positionStream.listen((pos) {
      if (!_positionController.isClosed) {
        _positionController.add(_unifiedPosition);
      }
      _schedulePositionBroadcast();
      _maybeSavePosition();
    }));

    // Buffered position → internal broadcast only
    _subs.add(_player.bufferedPositionStream
        .listen((_) => _scheduleBroadcast(structural: false)));

    // Duration → stable controller + internal side-effects
    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      if (!_durationController.isClosed) {
        _durationController.add(_unifiedDuration);
      }
      _maybeReschedulePreloadTimer();
      _scheduleBroadcast(structural: true);
    }));

    // PlayerState → stable controller + internal broadcast
    _subs.add(_player.playerStateStream.listen((ps) {
      if (!_playerStateController.isClosed) {
        _playerStateController.add(ps);
      }
      _scheduleBroadcast(structural: true);
    }));
  }

  // ── Item completion ────────────────────────────────────────────────────────
  //
  // Loop mode behaviour after this fix:
  //   LoopMode.off  — advances track-by-track through the queue, stops at end.
  //   LoopMode.all  — wraps back to index 0 when last track finishes.
  //                   (1st loop-button tap — "repeat album/queue")
  //   LoopMode.one  — replays current track forever.
  //                   (2nd loop-button tap — "repeat single")
  void _handleItemCompletion() {
    switch (_loopMode) {
      case ja.LoopMode.one:
        // Repeat same track forever.
        _playItemAtQueueIndex(_currentQueueIndex);
        break;
      case ja.LoopMode.all:
        // Repeat whole queue — wrap to index 0 after last track.
        final nextIdx = (_currentQueueIndex + 1) % _playableQueue.length;
        _handleTransitionTo(nextIdx);
        break;
      case ja.LoopMode.off:
        // Play linearly; stop naturally when last track finishes.
        if (_currentQueueIndex < _playableQueue.length - 1) {
          _handleTransitionTo(_currentQueueIndex + 1);
        }
        break;
    }
  }

  /// Transition to the given queue index, using the pre-loaded player if ready.
  Future<void> _handleTransitionTo(int nextIndex) async {
    if (_nextItemPreloaded && _nextItemPreloadIndex == nextIndex) {
      await _swapToNextItemPlayer(nextIndex);
    } else {
      await _playItemAtQueueIndex(nextIndex);
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
    _broadcastCritical();

    // Schedule background preload of the NEXT queue item.
    _scheduleNextItemPreload();
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
    _cancelNextItemPreload();
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
    _broadcastCritical();
  }

  @override
  Future<void> pause() async {
    _savePositionNow();
    await _player.pause();
    _broadcastCritical();
  }

  @override
  Future<void> stop() async {
    _savePositionNow();
    _cancelNextItemPreload();
    await _player.stop();
    _broadcastCritical();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_partUrls.length <= 1) {
      await _player.seek(position);
      // Push immediately into stable stream so UI snaps without waiting for
      // the next positionStream tick.
      if (!_positionController.isClosed) {
        _positionController.add(_unifiedPosition);
      }
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

      _maybePreloadNextPart(targetPart);
      _completionSub = _player.processingStateStream.listen((state) {
        if (state == ja.ProcessingState.completed) _onPartCompleted();
      });
    }
    if (!_positionController.isClosed) {
      _positionController.add(_unifiedPosition);
    }
    _broadcastCritical();
  }

  @override
  Future<void> skipToNext() async {
    _savePositionNow();
    _cancelNextItemPreload();
    if (_currentQueueIndex < _playableQueue.length - 1) {
      await _playItemAtQueueIndex(_currentQueueIndex + 1);
    } else if (_loopMode == ja.LoopMode.all && _playableQueue.isNotEmpty) {
      // FIX: When on last track with loop-all active, wrap to first track.
      await _playItemAtQueueIndex(0);
    }
    _broadcastCritical();
  }

  @override
  Future<void> skipToPrevious() async {
    _savePositionNow();
    _cancelNextItemPreload();
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
    _cancelNextItemPreload();
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
    // Reschedule preload since next-index may have changed.
    _cancelNextItemPreload();
    _scheduleNextItemPreload();
  }

  Future<void> toggleShuffle() async {
    _shuffleMode = !_shuffleMode;
    await _player.setShuffleModeEnabled(_shuffleMode);
  }

  // ── Streams / getters ──────────────────────────────────────────────────────
  // STABLE STREAMS: never change reference even when _player is swapped.
  // AudioPlayerNotifier subscribes once and keeps receiving events forever.
  Stream<Duration>       get positionStream    => _positionController.stream;
  Stream<Duration?>      get durationStream    => _durationController.stream;
  Stream<ja.PlayerState> get playerStateStream => _playerStateController.stream;
  Stream<double>         get speedStream       => _player.speedStream;

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
    _nextItemPreloadTimer?.cancel();
    await _completionSub?.cancel();
    for (final s in _subs) { s.cancel(); }
    await _positionController.close();
    await _durationController.close();
    await _playerStateController.close();
    await _player.dispose();
    await _preloadPlayer.dispose();
    await _nextItemPlayer.dispose();
  }
}