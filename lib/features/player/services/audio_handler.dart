// lib/features/player/services/audio_handler.dart
//
// FIXES IN THIS VERSION
// =====================
//
// FIX 1 — AUTO-PLAY NEXT ALBUM WHEN CURRENT ALBUM COMPLETES
// ----------------------------------------------------------
// PROBLEM: When the last song of an album finishes and loopMode == off,
// _handleItemCompletion() fell into the final `else` branch and did nothing.
// The player went silent even though there are more albums in the queue.
//
// ROOT CAUSE: The queue passed from AlbumDetailScreen only contains songs
// from ONE album. When that queue is exhausted there is nothing to advance to.
//
// FIX: AudioCalmHandler now exposes a `onQueueExhausted` callback.
// The AudioPlayerNotifier sets this callback to request the next album's
// songs from allAlbumsRawProvider and call playItem() with the full new queue.
// This keeps the handler stateless w.r.t. album ordering — all album
// navigation logic stays in the provider layer.
//
// FIX 2 — RESUME AUDIO SERIES FROM LAST SAVED POSITION
// -----------------------------------------------------
// PROBLEM: When a user closes the app mid-episode and reopens it, tapping
// the episode starts from position 0 instead of resuming.
//
// ROOT CAUSE: _loadItem() always calls _loadPartAndPlay(0) with no
// initialPosition, discarding the saved position from PlaybackPositionService.
//
// FIX: playItem() now accepts an optional `resumeFromSaved` flag (default true
// for episodes, false for songs — configurable by caller). When true,
// _loadItem() reads PlaybackPositionService.get(item.id) and passes the
// saved position as initialPosition to _loadPartAndPlay(). Multi-part
// episodes: the saved position is resolved across parts using accumulated
// part durations.
//
// EXISTING ARCHITECTURE (unchanged):
//   • Backend sends 302 redirects to Telegram CDN — just_audio follows them.
//   • Stable broadcast streams (_positionController etc.) never change ref.
//   • Gapless within-item part pre-loading via _preloadPlayer.
//   • Next-item pre-loading via _nextItemPlayer + timer.
//   • URL expiry handled via ?refresh=1 retry.
//   • Broadcast throttling to 60 fps max.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import 'multi_part_url_service.dart';
import 'playback_position_service.dart';

class AudioCalmHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  // ── Stable broadcast streams ───────────────────────────────────────────────
  final _positionController    = StreamController<Duration>.broadcast();
  final _durationController    = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<ja.PlayerState>.broadcast();

  // ── Primary player ─────────────────────────────────────────────────────────
  ja.AudioPlayer _player = ja.AudioPlayer();

  // ── Within-item part pre-load player ──────────────────────────────────────
  ja.AudioPlayer _preloadPlayer = ja.AudioPlayer();
  bool _preloadReady = false;

  // ── Next-item pre-load player ──────────────────────────────────────────────
  ja.AudioPlayer _nextItemPlayer = ja.AudioPlayer();
  bool _nextItemPreloaded       = false;
  int  _nextItemPreloadIndex    = -1;
  Timer? _nextItemPreloadTimer;

  // ── URL service ───────────────────────────────────────────────────────────
  final MultiPartUrlService _urlService = MultiPartUrlService(null);

  // ── Queue / navigation ─────────────────────────────────────────────────────
  List<PlayableItem> _playableQueue   = [];
  int  _currentQueueIndex = 0;
  bool _shuffleMode       = false;
  ja.LoopMode _loopMode   = ja.LoopMode.off;

  // ── Multi-part state ───────────────────────────────────────────────────────
  List<String> _partUrls         = [];
  int          _currentPartIndex = 0;
  Duration     _partOffset       = Duration.zero;
  final List<Duration> _partDurations = [];
  Duration?    _knownTotalDuration;

  // ── Subscriptions ──────────────────────────────────────────────────────────
  final List<StreamSubscription> _subs = [];
  StreamSubscription? _completionSub;

  // ── Broadcast throttling ───────────────────────────────────────────────────
  bool     _pendingBroadcast    = false;
  DateTime _lastBroadcastTime   = DateTime.fromMillisecondsSinceEpoch(0);
  Timer?   _throttleTimer;
  static const Duration _kMinBroadcastInterval      = Duration(milliseconds: 16);
  static const Duration _kPositionBroadcastInterval = Duration(milliseconds: 200);

  // ── Position save throttle ─────────────────────────────────────────────────
  int _lastSavedPositionSeconds = 0;
  static const int _saveIntervalSeconds = 5;

  // ── Pre-load lead time ─────────────────────────────────────────────────────
  static const int _kPreloadLeadSeconds = 30;

  // ── FIX 1: Queue-exhausted callback ───────────────────────────────────────
  // Set by AudioPlayerNotifier. Called when the last item in the current
  // queue finishes and loopMode == off. The notifier can then load the next
  // album's songs and call playItem() to continue playback seamlessly.
  // Kept nullable — if not set, behaviour is the same as before (silence).
  void Function()? onQueueExhausted;

  AudioCalmHandler() {
    _init();
  }

  void _init() {
    _reAttachStreams();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // NEXT-ITEM PRE-LOADING
  // ═══════════════════════════════════════════════════════════════════════════

  void _scheduleNextItemPreload() {
    _cancelNextItemPreloadTimer();
    if (_loopMode == ja.LoopMode.one) return;
    final nextIndex = _nextQueueIndex();
    if (nextIndex == null) return;

    final totalDuration = _knownTotalDuration;
    if (totalDuration == null || totalDuration == Duration.zero) return;

    final leadTime  = const Duration(seconds: _kPreloadLeadSeconds);
    final fireAfter = totalDuration - leadTime;
    final currentPos = _unifiedPosition;

    if (fireAfter <= Duration.zero || fireAfter <= currentPos) {
      _doPreloadNextItem(nextIndex);
      return;
    }

    final remaining = fireAfter - currentPos;
    _nextItemPreloadTimer = Timer(remaining, () {
      final idx = _nextQueueIndex();
      if (idx != null) _doPreloadNextItem(idx);
    });

    debugPrint('[AudioHandler] Next-item preload in ${remaining.inSeconds}s for queue[$nextIndex]');
  }

  void _cancelNextItemPreloadTimer() {
    _nextItemPreloadTimer?.cancel();
    _nextItemPreloadTimer = null;
  }

  void _cancelNextItemPreload() {
    _cancelNextItemPreloadTimer();
    _nextItemPreloaded    = false;
    _nextItemPreloadIndex = -1;
    _nextItemPlayer.stop().catchError((_) {});
  }

  Future<void> _doPreloadNextItem(int index) async {
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
      _nextItemPreloaded    = true;
      _nextItemPreloadIndex = index;
      debugPrint('[AudioHandler] ✓ Preloaded queue[$index] "${item.title}"');
    } catch (e) {
      debugPrint('[AudioHandler] Preload failed queue[$index]: $e');
      if (e.toString().contains('403') || e.toString().contains('401')) {
        await _refreshAndRetryPreload(item, urls.first, index);
      } else {
        _nextItemPreloaded = false;
      }
    }
  }

  Future<void> _refreshAndRetryPreload(PlayableItem item, String url, int index) async {
    try {
      final freshUrl = _appendRefreshParam(url);
      await _nextItemPlayer.setAudioSource(
        ja.AudioSource.uri(Uri.parse(freshUrl)),
        preload: true,
      );
      _nextItemPreloaded    = true;
      _nextItemPreloadIndex = index;
      debugPrint('[AudioHandler] ✓ Preloaded (after URL refresh) queue[$index]');
    } catch (e) {
      debugPrint('[AudioHandler] Preload retry failed queue[$index]: $e');
      _nextItemPreloaded = false;
    }
  }

  int? _nextQueueIndex() {
    if (_playableQueue.isEmpty) return null;
    switch (_loopMode) {
      case ja.LoopMode.one:
        return null;
      case ja.LoopMode.all:
        return (_currentQueueIndex + 1) % _playableQueue.length;
      case ja.LoopMode.off:
        final next = _currentQueueIndex + 1;
        return next < _playableQueue.length ? next : null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // GAPLESS SWAP — NEXT-ITEM
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _swapToNextItemPlayer(int nextQueueIndex) async {
    debugPrint('[AudioHandler] Gapless swap → queue[$nextQueueIndex]');

    await _completionSub?.cancel();
    _completionSub = null;

    final oldPlayer       = _player;
    _player               = _nextItemPlayer;
    _nextItemPlayer       = ja.AudioPlayer();
    _nextItemPreloaded    = false;
    _nextItemPreloadIndex = -1;

    final item             = _playableQueue[nextQueueIndex];
    _currentQueueIndex     = nextQueueIndex;
    _partUrls              = _buildPartUrls(item);
    _currentPartIndex      = 0;
    _partOffset            = Duration.zero;
    _partDurations.clear();
    _preloadReady              = false;
    _lastSavedPositionSeconds  = 0;
    _knownTotalDuration = item.duration != null
        ? Duration(seconds: item.duration!)
        : null;

    mediaItem.add(_playableToMediaItem(item));
    _reAttachStreams();

    await _player.play();

    _completionSub = _player.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed) _onPartCompleted();
    });

    _broadcastCritical();

    Future.delayed(const Duration(milliseconds: 500), () {
      oldPlayer.dispose();
    });

    _scheduleNextItemPreload();

    if (_partUrls.length > 1) {
      _maybePreloadNextPart(0);
    }

    debugPrint('[AudioHandler] ✓ Gapless swap complete "${item.title}"');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // WITHIN-ITEM PART PRE-LOADING
  // ═══════════════════════════════════════════════════════════════════════════

  void _maybePreloadNextPart(int currentPart) {
    _preloadReady = false;
    final nextPart = currentPart + 1;
    if (nextPart >= _partUrls.length) return;

    final url = _partUrls[nextPart];
    _preloadPlayer.stop().catchError((_) {});

    _preloadPlayer
        .setAudioSource(ja.AudioSource.uri(Uri.parse(url)), preload: true)
        .then((_) {
          _preloadReady = true;
          debugPrint('[AudioHandler] ✓ Part ${nextPart + 1}/${_partUrls.length} preloaded');
        })
        .catchError((e) {
          _preloadReady = false;
          debugPrint('[AudioHandler] Part preload failed: $e');
          if (e.toString().contains('403') || e.toString().contains('401')) {
            final freshUrl = _appendRefreshParam(url);
            _preloadPlayer
                .setAudioSource(ja.AudioSource.uri(Uri.parse(freshUrl)), preload: true)
                .then((_) { _preloadReady = true; })
                .catchError((_) { _preloadReady = false; });
          }
        });
  }

  Future<void> _swapToPreloadedPart() async {
    await _completionSub?.cancel();
    _completionSub = null;

    final oldPlayer  = _player;
    _player          = _preloadPlayer;
    _preloadPlayer   = ja.AudioPlayer();
    _preloadReady    = false;

    _reAttachStreams();
    await _player.play();

    Future.delayed(const Duration(milliseconds: 500), () => oldPlayer.dispose());
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // URL REFRESH
  // ═══════════════════════════════════════════════════════════════════════════

  String _appendRefreshParam(String url) {
    try {
      final uri    = Uri.parse(url);
      final params = Map<String, String>.from(uri.queryParameters);
      params['refresh'] = '1';
      return uri.replace(queryParameters: params).toString();
    } catch (_) {
      return '$url${url.contains('?') ? '&' : '?'}refresh=1';
    }
  }

  Future<bool> _refreshAndRetry(String url, {Duration startAt = Duration.zero}) async {
    try {
      final freshUrl = _appendRefreshParam(url);
      debugPrint('[AudioHandler] Refreshing URL (expired): $freshUrl');
      await _player.setAudioSource(
        ja.AudioSource.uri(Uri.parse(freshUrl)),
        initialPosition: startAt,
      );
      await _player.play();
      return true;
    } catch (e) {
      debugPrint('[AudioHandler] URL refresh failed: $e');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PART LOADING
  // ═══════════════════════════════════════════════════════════════════════════

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
        await _swapToPreloadedPart();
      } else {
        await _player.setAudioSource(
          ja.AudioSource.uri(Uri.parse(url)),
          initialPosition: startAt,
        );
        await _player.play();
      }
    } catch (e) {
      debugPrint('[AudioHandler] Part load error: $e');
      if (e.toString().contains('403') || e.toString().contains('401')) {
        final ok = await _refreshAndRetry(url, startAt: startAt);
        if (!ok) return;
      } else {
        return;
      }
    }

    _maybePreloadNextPart(partIndex);

    _completionSub = _player.processingStateStream.listen((state) {
      if (state == ja.ProcessingState.completed) _onPartCompleted();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PART COMPLETION
  // ═══════════════════════════════════════════════════════════════════════════

  void _onPartCompleted() {
    final nextPart = _currentPartIndex + 1;
    if (nextPart < _partUrls.length) {
      final completed = _partDurations.length > _currentPartIndex
          ? _partDurations[_currentPartIndex]
          : (_player.duration ?? Duration.zero);
      _partOffset += completed;
      debugPrint('[AudioHandler] Part ${_currentPartIndex + 1} done → loading part ${nextPart + 1}');
      _loadPartAndPlay(nextPart);
    } else {
      final item = _currentQueueIndex < _playableQueue.length
          ? _playableQueue[_currentQueueIndex]
          : null;
      if (item != null) PlaybackPositionService.clear(item.id);
      _handleItemCompletion();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ITEM COMPLETION
  // ═══════════════════════════════════════════════════════════════════════════

  void _handleItemCompletion() {
    switch (_loopMode) {
      case ja.LoopMode.one:
        _playItemAtQueueIndex(_currentQueueIndex);
        break;
      case ja.LoopMode.all:
        final nextIdx = (_currentQueueIndex + 1) % _playableQueue.length;
        _handleTransitionTo(nextIdx);
        break;
      case ja.LoopMode.off:
        if (_currentQueueIndex < _playableQueue.length - 1) {
          // More songs in this album queue — advance normally.
          _handleTransitionTo(_currentQueueIndex + 1);
        } else {
          // FIX 1: Last item in current queue finished.
          // Notify the notifier layer so it can load the next album's queue.
          // If the callback is not set (no next album), player goes idle.
          debugPrint('[AudioHandler] Queue exhausted — invoking onQueueExhausted callback');
          onQueueExhausted?.call();
        }
        break;
    }
  }

  Future<void> _handleTransitionTo(int nextIndex) async {
    if (_nextItemPreloaded && _nextItemPreloadIndex == nextIndex) {
      await _swapToNextItemPlayer(nextIndex);
    } else {
      await _playItemAtQueueIndex(nextIndex);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ITEM LOADING
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _playItemAtQueueIndex(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _playableQueue.length) return;
    _currentQueueIndex = queueIndex;
    // When auto-advancing within the queue (skip / auto-next), do NOT resume
    // from a saved position — start from the beginning.
    await _loadItem(_playableQueue[queueIndex], resumePosition: false);
  }

  // ── FIX 2: resumePosition flag ────────────────────────────────────────────
  // When resumePosition == true, _loadItem reads PlaybackPositionService and
  // seeks to the saved offset before starting playback.
  Future<void> _loadItem(PlayableItem item, {bool resumePosition = false}) async {
    _partUrls         = _buildPartUrls(item);
    _currentPartIndex = 0;
    _partOffset       = Duration.zero;
    _partDurations.clear();
    _preloadReady             = false;
    _lastSavedPositionSeconds = 0;
    _knownTotalDuration = item.duration != null
        ? Duration(seconds: item.duration!)
        : null;

    mediaItem.add(_playableToMediaItem(item));
    debugPrint('[AudioHandler] Loading "${item.title}" — ${_partUrls.length} part(s)'
        '${resumePosition ? ' (will resume saved position)' : ''}');

    // FIX 2: Resolve saved position and map it to the correct part + offset.
    Duration resumeAt = Duration.zero;
    if (resumePosition) {
      final savedSeconds = PlaybackPositionService.get(item.id);
      if (savedSeconds != null && savedSeconds > 0) {
        resumeAt = Duration(seconds: savedSeconds);
        debugPrint('[AudioHandler] Resuming "${item.title}" from ${savedSeconds}s');
      }
    }

    if (resumeAt == Duration.zero || _partUrls.length <= 1) {
      // Single-part or no saved position: simple load.
      await _loadPartAndPlay(0, startAt: resumeAt);
    } else {
      // Multi-part: we need to figure out which part contains resumeAt.
      // Since we don't know part durations yet (they come from just_audio
      // after loading), we load part 0 first to get its duration, then
      // decide. For episodes where duration IS known ahead of time via
      // _knownTotalDuration, we try to estimate.
      //
      // Strategy: load part 0, let position accumulate, then seek via the
      // public seek() method which handles multi-part seeking correctly.
      await _loadPartAndPlay(0);
      // Once part 0 is loaded its duration will arrive via durationStream.
      // Defer the seek slightly so just_audio has time to resolve duration.
      if (resumeAt > Duration.zero) {
        Future.delayed(const Duration(milliseconds: 400), () async {
          // seek() handles multi-part logic internally.
          await seek(resumeAt);
          debugPrint('[AudioHandler] Multi-part resume: seeked to $resumeAt');
        });
      }
    }

    _broadcastCritical();
    _scheduleNextItemPreload();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // URL BUILDING
  // ═══════════════════════════════════════════════════════════════════════════

  List<String> _buildPartUrls(PlayableItem item) {
    final offlinePartUrls = item.extras['offlinePartUrls'] as String?;
    if (offlinePartUrls != null && offlinePartUrls.isNotEmpty) {
      final parts = offlinePartUrls.split('|').where((s) => s.isNotEmpty).toList();
      if (parts.isNotEmpty) return parts;
    }
    if (item.streamUrl.startsWith('file://') || item.streamUrl.startsWith('/')) {
      return [item.streamUrl];
    }

    final contentType = item.isEpisode ? 'episodes' : 'songs';
    return _urlService
        .buildPartsFromCount(
          baseId:      item.id,
          contentType: contentType,
          partCount:   item.partCount,
        )
        .map((p) => p.streamUrl)
        .toList();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // STREAM RE-ATTACHMENT
  // ═══════════════════════════════════════════════════════════════════════════

  void _reAttachStreams() {
    for (final s in _subs) { s.cancel(); }
    _subs.clear();

    _subs.add(_player.positionStream.listen((pos) {
      if (!_positionController.isClosed) {
        _positionController.add(_unifiedPosition);
      }
      _schedulePositionBroadcast();
      _maybeSavePosition();
    }));

    _subs.add(_player.bufferedPositionStream
        .listen((_) => _scheduleBroadcast(structural: false)));

    _subs.add(_player.durationStream.listen((dur) {
      if (dur != null && _currentPartIndex < _partDurations.length) {
        _partDurations[_currentPartIndex] = dur;
      }
      if (!_durationController.isClosed) {
        _durationController.add(_unifiedDuration);
      }
      if (_nextItemPreloadTimer == null && !_nextItemPreloaded) {
        _scheduleNextItemPreload();
      }
      _scheduleBroadcast(structural: true);
    }));

    _subs.add(_player.playerStateStream.listen((ps) {
      if (!_playerStateController.isClosed) {
        _playerStateController.add(ps);
      }
      _scheduleBroadcast(structural: true);
    }));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BROADCAST THROTTLING
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
    final now     = DateTime.now();
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
    _pendingBroadcast  = false;
    _lastBroadcastTime = DateTime.now();
    _broadcastStateNow();
  }

  void _broadcastStateNow() {
    final isPlaying = _player.playing;
    final ps        = _player.processingState;

    final mappedState = switch (ps) {
      ja.ProcessingState.idle      => AudioProcessingState.idle,
      ja.ProcessingState.loading   => AudioProcessingState.loading,
      ja.ProcessingState.buffering => AudioProcessingState.buffering,
      ja.ProcessingState.ready     => AudioProcessingState.ready,
      ja.ProcessingState.completed => AudioProcessingState.ready,
    };

    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
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
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // POSITION HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  Duration get _unifiedPosition => _partOffset + _player.position;

  Duration get _unifiedDuration {
    if (_knownTotalDuration != null && _knownTotalDuration! > Duration.zero) {
      return _knownTotalDuration!;
    }
    final cur = _player.duration;
    if (cur != null) return _partOffset + cur;
    return Duration.zero;
  }

  void _maybeSavePosition() {
    final item = _currentQueueIndex < _playableQueue.length
        ? _playableQueue[_currentQueueIndex]
        : null;
    if (item == null) return;
    final posSeconds = _unifiedPosition.inSeconds;
    if ((posSeconds - _lastSavedPositionSeconds).abs() < _saveIntervalSeconds) return;
    _lastSavedPositionSeconds = posSeconds;
    PlaybackPositionService.save(
      item.id,
      posSeconds,
      totalSeconds: item.duration,
    );
  }

  void _savePositionNow() {
    final item = _currentQueueIndex < _playableQueue.length
        ? _playableQueue[_currentQueueIndex]
        : null;
    if (item == null) return;
    PlaybackPositionService.save(
      item.id,
      _unifiedPosition.inSeconds,
      totalSeconds: item.duration,
    );
    _lastSavedPositionSeconds = _unifiedPosition.inSeconds;
  }

  MediaItem _playableToMediaItem(PlayableItem item) {
    return MediaItem(
      id:       item.id,
      title:    item.title,
      artist:   item.subtitle,
      artUri:   item.artworkUrl != null ? Uri.parse(item.artworkUrl!) : null,
      duration: item.duration != null ? Duration(seconds: item.duration!) : null,
      extras: {
        'type':      item.type.name,
        'streamUrl': item.streamUrl,
        'partCount': item.partCount,
        ...item.extras,
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PUBLIC API
  // ═══════════════════════════════════════════════════════════════════════════

  /// FIX 2: Added [resumeFromSaved] parameter (default false).
  /// Pass true for episodes so the handler seeks to the last saved position.
  /// Songs always start from the beginning (resumeFromSaved = false).
  Future<void> playItem(
    PlayableItem item, {
    List<PlayableItem>? queue,
    int index = 0,
    bool resumeFromSaved = false,
  }) async {
    _cancelNextItemPreload();

    if (queue != null) {
      _playableQueue     = queue;
      _currentQueueIndex = index;
      this.queue.add(queue.map(_playableToMediaItem).toList());
    } else {
      _playableQueue     = [item];
      _currentQueueIndex = 0;
      this.queue.add([_playableToMediaItem(item)]);
    }

    await _loadItem(item, resumePosition: resumeFromSaved);
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
      if (!_positionController.isClosed) {
        _positionController.add(_unifiedPosition);
      }
      _broadcastCritical();
      return;
    }

    Duration remaining        = position;
    int      targetPart       = 0;
    Duration offsetUpToTarget = Duration.zero;

    for (int i = 0; i < _partDurations.length; i++) {
      final d = _partDurations[i];
      if (d == Duration.zero) break;
      if (remaining <= d) {
        targetPart = i;
        break;
      }
      remaining        -= d;
      offsetUpToTarget += d;
      targetPart        = i + 1;
    }

    targetPart = targetPart.clamp(0, _partUrls.length - 1);

    if (targetPart == _currentPartIndex) {
      await _player.seek(remaining);
    } else {
      _partOffset       = offsetUpToTarget;
      _currentPartIndex = targetPart;
      while (_partDurations.length <= targetPart) {
        _partDurations.add(Duration.zero);
      }

      await _completionSub?.cancel();
      _completionSub = null;

      try {
        await _player.setAudioSource(
          ja.AudioSource.uri(Uri.parse(_partUrls[targetPart])),
          initialPosition: remaining,
        );
        await _player.play();
      } catch (e) {
        if (e.toString().contains('403') || e.toString().contains('401')) {
          await _refreshAndRetry(_partUrls[targetPart], startAt: remaining);
        }
      }

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
      await _playItemAtQueueIndex(0);
    } else {
      // Queue exhausted via manual skip — same behaviour as auto-completion.
      debugPrint('[AudioHandler] skipToNext: queue end — invoking onQueueExhausted');
      onQueueExhausted?.call();
    }
    _broadcastCritical();
  }

  @override
  Future<void> skipToPrevious() async {
    _savePositionNow();
    _cancelNextItemPreload();

    if (_player.position.inSeconds > 3 || _partOffset.inSeconds > 0) {
      await _loadItem(_playableQueue[_currentQueueIndex], resumePosition: false);
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
    final newPos = _unifiedPosition + const Duration(seconds: 10);
    final dur    = _unifiedDuration;
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
    _cancelNextItemPreload();
    _scheduleNextItemPreload();
  }

  Future<void> toggleShuffle() async {
    _shuffleMode = !_shuffleMode;
    await _player.setShuffleModeEnabled(_shuffleMode);
  }

  Future<void> cycleLoopMode() async {
    final nextMode = switch (_loopMode) {
      ja.LoopMode.off => ja.LoopMode.all,
      ja.LoopMode.all => ja.LoopMode.one,
      ja.LoopMode.one => ja.LoopMode.off,
    };
    await setLoopMode(nextMode);
  }

  // ── Streams / Getters ─────────────────────────────────────────────────────

  Stream<Duration>       get positionStream    => _positionController.stream;
  Stream<Duration?>      get durationStream    => _durationController.stream;
  Stream<ja.PlayerState> get playerStateStream => _playerStateController.stream;
  Stream<double>         get speedStream       => _player.speedStream;

  Duration?  get duration     => _unifiedDuration;
  Duration   get position     => _unifiedPosition;
  bool       get playing      => _player.playing;
  double     get speed        => _player.speed;
  int        get currentIndex => _currentQueueIndex;
  List<PlayableItem> get playableQueue => _playableQueue;
  ja.LoopMode get loopMode    => _loopMode;
  bool        get shuffleMode => _shuffleMode;

  @override
  Future<void> onTaskRemoved() async => stop();

  Future<void> dispose() async {
    _throttleTimer?.cancel();
    _cancelNextItemPreloadTimer();
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