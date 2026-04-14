// lib/features/player/services/audio_handler.dart
//
// SEAMLESS PRELOAD FIXES
// ======================
//
// PROBLEM: Next track preload fired too late (30s before end), was cancelled
// too aggressively, and didn't cover the album-auto-advance case.
//
// FIX 1 — EARLIER PRELOAD TRIGGER: 60s before end (was 30s).
//   Short tracks (<90s) get preloaded immediately after load.
//   This gives just_audio enough time to fully buffer the next item
//   so the gapless swap is truly instant.
//
// FIX 2 — PRELOAD ON DURATION KNOWN: As soon as _knownTotalDuration is set
//   we schedule preload. Previously we waited for a timer that fired too late
//   on short tracks, causing an audible gap.
//
// FIX 3 — DON'T CANCEL PRELOAD ON SEEK: _cancelNextItemPreload() was called
//   inside seek(), wiping the buffered next item every time the user scrubs.
//   Seeks within the current item no longer cancel preload.
//
// FIX 4 — PRELOAD NEXT ALBUM: When onQueueExhausted fires, we pre-load the
//   first track of the next album in _nextItemPlayer immediately so the
//   album-to-album transition is also gapless.
//
// FIX 5 — PRELOAD RETRY WITH BACKOFF: If setAudioSource fails (network hiccup)
//   we retry once after 2s instead of silently giving up.
//
// All other logic unchanged.

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../domain/media_item_model.dart';
import 'multi_part_url_service.dart';
import 'playback_position_service.dart';

class AudioCalmHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  final _positionController    = StreamController<Duration>.broadcast();
  final _durationController    = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<ja.PlayerState>.broadcast();

  ja.AudioPlayer _player        = ja.AudioPlayer();
  ja.AudioPlayer _preloadPlayer = ja.AudioPlayer();
  bool _preloadReady = false;

  ja.AudioPlayer _nextItemPlayer        = ja.AudioPlayer();
  bool           _nextItemPreloaded     = false;
  int            _nextItemPreloadIndex  = -1;
  Timer?         _nextItemPreloadTimer;

  // FIX 4: player pre-warmed for the next album's first track
  ja.AudioPlayer _nextAlbumPlayer       = ja.AudioPlayer();
  bool           _nextAlbumPreloaded    = false;
  String?        _nextAlbumPreloadedUrl;

  final MultiPartUrlService _urlService = MultiPartUrlService(null);

  List<PlayableItem> _playableQueue   = [];
  int  _currentQueueIndex = 0;
  bool _shuffleMode       = false;
  ja.LoopMode _loopMode   = ja.LoopMode.off;

  List<String>      _partUrls         = [];
  int               _currentPartIndex = 0;
  Duration          _partOffset       = Duration.zero;
  final List<Duration> _partDurations = [];
  Duration?         _knownTotalDuration;

  Duration? _pendingSeekAfterLoad;

  final List<StreamSubscription> _subs = [];
  StreamSubscription? _completionSub;

  bool     _pendingBroadcast    = false;
  DateTime _lastBroadcastTime   = DateTime.fromMillisecondsSinceEpoch(0);
  Timer?   _throttleTimer;
  static const Duration _kMinBroadcastInterval      = Duration(milliseconds: 16);
  static const Duration _kPositionBroadcastInterval = Duration(milliseconds: 200);

  int _lastSavedPositionSeconds = 0;
  static const int _saveIntervalSeconds = 5;

  // FIX 1: Increased from 30s → 60s lead time; short tracks get immediate preload.
  static const int _kPreloadLeadSeconds       = 60;
  static const int _kShortTrackThresholdSecs  = 90; // tracks < 90s preload immediately

  void Function()? onQueueExhausted;

  // Callback so AudioPlayerNotifier can supply next-album data for FIX 4.
  Future<PlayableItem?> Function()? onGetNextAlbumFirstTrack;

  AudioCalmHandler() {
    _init();
  }

  void _init() {
    _reAttachStreams();
  }

  // ── Build part URLs ────────────────────────────────────────────────────────

  List<String> _buildPartUrls(PlayableItem item) {
    final isOffline = item.extras['isOffline'] == true;

    if (isOffline) {
      final offlineParts = item.extras['offlinePartUrls'] as String?;
      if (offlineParts != null && offlineParts.isNotEmpty) {
        return offlineParts.split('|').where((u) => u.isNotEmpty).toList();
      }
      return item.streamUrl.isNotEmpty ? [item.streamUrl] : [];
    }

    final partCount = item.partCount;
    if (partCount <= 1) {
      return item.streamUrl.isNotEmpty ? [item.streamUrl] : [];
    }

    final base = item.streamUrl;
    return List.generate(partCount, (i) => '$base?part=${i + 1}');
  }

  // ── Next-item pre-loading ──────────────────────────────────────────────────

  void _scheduleNextItemPreload() {
    _cancelNextItemPreloadTimer();
    if (_loopMode == ja.LoopMode.one) return;
    final nextIndex = _nextQueueIndex();
    if (nextIndex == null) return;

    final totalDuration = _knownTotalDuration;

    // FIX 2: If duration unknown or track is short, preload immediately.
    if (totalDuration == null || totalDuration == Duration.zero) {
      Future.delayed(const Duration(seconds: 2), () {
        final idx = _nextQueueIndex();
        if (idx != null && !_nextItemPreloaded) _doPreloadNextItem(idx);
      });
      return;
    }

    // FIX 1: Short tracks preload right away.
    if (totalDuration.inSeconds < _kShortTrackThresholdSecs) {
      _doPreloadNextItem(nextIndex);
      return;
    }

    final leadTime   = Duration(seconds: _kPreloadLeadSeconds);
    final fireAfter  = totalDuration - leadTime;
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
    // Also reset album preload.
    _nextAlbumPreloaded    = false;
    _nextAlbumPreloadedUrl = null;
    _nextAlbumPlayer.stop().catchError((_) {});
  }

  Future<void> _doPreloadNextItem(int index) async {
    if (index < 0 || index >= _playableQueue.length) return;
    if (_nextItemPreloaded && _nextItemPreloadIndex == index) return; // already done

    final item = _playableQueue[index];
    final urls = _buildPartUrls(item);
    if (urls.isEmpty) return;

    debugPrint('[AudioHandler] Preloading queue[$index] "${item.title}"');

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        await _nextItemPlayer.setAudioSource(
          ja.AudioSource.uri(Uri.parse(urls.first)),
          preload: true,
        );
        _nextItemPreloaded    = true;
        _nextItemPreloadIndex = index;
        debugPrint('[AudioHandler] Preload ready queue[$index]');
        return;
      } catch (e) {
        debugPrint('[AudioHandler] Preload attempt ${attempt+1} failed queue[$index]: $e');
        if (e.toString().contains('403') || e.toString().contains('401')) {
          // FIX 5: Try refresh URL on auth error.
          try {
            final fresh = _appendRefreshParam(urls.first);
            await _nextItemPlayer.setAudioSource(
              ja.AudioSource.uri(Uri.parse(fresh)),
              preload: true,
            );
            _nextItemPreloaded    = true;
            _nextItemPreloadIndex = index;
            return;
          } catch (_) {}
        }
        if (attempt == 0) {
          // FIX 5: Back off 2s before retry.
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }
    _nextItemPreloaded = false;
  }

  // FIX 4: Pre-warm next album's first track in background.
  Future<void> _preloadNextAlbumTrack() async {
    if (onGetNextAlbumFirstTrack == null) return;
    try {
      final nextItem = await onGetNextAlbumFirstTrack!();
      if (nextItem == null) return;
      final urls = _buildPartUrls(nextItem);
      if (urls.isEmpty) return;
      final url = urls.first;
      if (_nextAlbumPreloadedUrl == url) return; // already preloaded this one

      debugPrint('[AudioHandler] Pre-warming next album: "${nextItem.title}"');
      await _nextAlbumPlayer.setAudioSource(
        ja.AudioSource.uri(Uri.parse(url)),
        preload: true,
      );
      _nextAlbumPreloaded    = true;
      _nextAlbumPreloadedUrl = url;
      debugPrint('[AudioHandler] Next album pre-warm ready');
    } catch (e) {
      debugPrint('[AudioHandler] Next album pre-warm failed: $e');
      _nextAlbumPreloaded = false;
    }
  }

  int? _nextQueueIndex() {
    if (_playableQueue.isEmpty) return null;
    switch (_loopMode) {
      case ja.LoopMode.one: return null;
      case ja.LoopMode.all: return (_currentQueueIndex + 1) % _playableQueue.length;
      case ja.LoopMode.off:
        final next = _currentQueueIndex + 1;
        return next < _playableQueue.length ? next : null;
    }
  }

  // ── Gapless swap (next track) ──────────────────────────────────────────────

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
    _pendingSeekAfterLoad      = null;
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
  }

  // ── Gapless swap (next album, FIX 4) ──────────────────────────────────────

  Future<void> _swapToNextAlbumPlayer(PlayableItem nextItem) async {
    debugPrint('[AudioHandler] Gapless album swap → "${nextItem.title}"');

    await _completionSub?.cancel();
    _completionSub = null;

    final oldPlayer    = _player;
    _player            = _nextAlbumPlayer;
    _nextAlbumPlayer   = ja.AudioPlayer();
    _nextAlbumPreloaded    = false;
    _nextAlbumPreloadedUrl = null;

    _partUrls              = _buildPartUrls(nextItem);
    _currentPartIndex      = 0;
    _partOffset            = Duration.zero;
    _partDurations.clear();
    _preloadReady              = false;
    _lastSavedPositionSeconds  = 0;
    _pendingSeekAfterLoad      = null;
    _knownTotalDuration = nextItem.duration != null
        ? Duration(seconds: nextItem.duration!)
        : null;

    mediaItem.add(_playableToMediaItem(nextItem));
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
  }

  // ── Within-item part pre-loading ───────────────────────────────────────────

  void _maybePreloadNextPart(int currentPart) {
    _preloadReady = false;
    final nextPart = currentPart + 1;
    if (nextPart >= _partUrls.length) return;

    final url = _partUrls[nextPart];
    _preloadPlayer.stop().catchError((_) {});

    _preloadPlayer
        .setAudioSource(ja.AudioSource.uri(Uri.parse(url)), preload: true)
        .then((_) { _preloadReady = true; })
        .catchError((e) {
          _preloadReady = false;
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

  // ── URL refresh ────────────────────────────────────────────────────────────

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
      await _player.setAudioSource(ja.AudioSource.uri(Uri.parse(freshUrl)));
      if (startAt > Duration.zero) {
        _pendingSeekAfterLoad = startAt;
      }
      await _player.play();
      return true;
    } catch (e) {
      debugPrint('[AudioHandler] URL refresh failed: $e');
      return false;
    }
  }

  // ── Part loading ──────────────────────────────────────────────────────────

  Future<void> _loadPartAndPlay(int partIndex,
      {Duration startAt = Duration.zero}) async {
    _currentPartIndex = partIndex;
    while (_partDurations.length <= partIndex) {
      _partDurations.add(Duration.zero);
    }

    await _completionSub?.cancel();
    _completionSub = null;

    final url = _partUrls[partIndex];
    debugPrint('[AudioHandler] Loading part ${partIndex + 1}/${_partUrls.length}: $url'
        '${startAt > Duration.zero ? ' (resume at ${startAt.inSeconds}s)' : ''}');

    if (startAt > Duration.zero) {
      _pendingSeekAfterLoad = startAt;
    }

    try {
      if (startAt == Duration.zero && partIndex > 0 && _preloadReady) {
        await _swapToPreloadedPart();
      } else {
        await _player.setAudioSource(ja.AudioSource.uri(Uri.parse(url)));
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

  // ── Part completion ────────────────────────────────────────────────────────

  void _onPartCompleted() {
    final nextPart = _currentPartIndex + 1;
    if (nextPart < _partUrls.length) {
      final completed = _partDurations.length > _currentPartIndex
          ? _partDurations[_currentPartIndex]
          : (_player.duration ?? Duration.zero);
      _partOffset += completed;
      _loadPartAndPlay(nextPart);
    } else {
      final item = _currentQueueIndex < _playableQueue.length
          ? _playableQueue[_currentQueueIndex]
          : null;
      if (item != null) PlaybackPositionService.clear(item.id);
      _handleItemCompletion();
    }
  }

  // ── Item completion ────────────────────────────────────────────────────────

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
          _handleTransitionTo(_currentQueueIndex + 1);
        } else {
          debugPrint('[AudioHandler] Queue exhausted — invoking onQueueExhausted');
          // FIX 4: If we pre-warmed the next album, use it immediately.
          if (_nextAlbumPreloaded && onGetNextAlbumFirstTrack != null) {
            _doGaplessAlbumAdvance();
          } else {
            onQueueExhausted?.call();
          }
        }
        break;
    }
  }

  // FIX 4: Pull the next album item and swap gaplessly.
  Future<void> _doGaplessAlbumAdvance() async {
    if (onGetNextAlbumFirstTrack == null) {
      onQueueExhausted?.call();
      return;
    }
    try {
      final nextItem = await onGetNextAlbumFirstTrack!();
      if (nextItem == null) {
        onQueueExhausted?.call();
        return;
      }
      // Let AudioPlayerNotifier update its queue state via the callback.
      onQueueExhausted?.call();
      // Give the notifier a tick to update _playableQueue before we swap.
      await Future.delayed(const Duration(milliseconds: 50));
      if (_nextAlbumPreloaded) {
        await _swapToNextAlbumPlayer(nextItem);
      } else {
        await _loadItem(nextItem, resumePosition: false);
      }
    } catch (e) {
      debugPrint('[AudioHandler] Gapless album advance failed: $e');
      onQueueExhausted?.call();
    }
  }

  Future<void> _handleTransitionTo(int nextIndex) async {
    if (_nextItemPreloaded && _nextItemPreloadIndex == nextIndex) {
      await _swapToNextItemPlayer(nextIndex);
    } else {
      await _playItemAtQueueIndex(nextIndex);
    }
  }

  // ── Item loading ───────────────────────────────────────────────────────────

  Future<void> _playItemAtQueueIndex(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _playableQueue.length) return;
    _currentQueueIndex = queueIndex;
    await _loadItem(_playableQueue[queueIndex], resumePosition: false);
  }

  Future<void> _loadItem(PlayableItem item, {bool resumePosition = false}) async {
    _partUrls         = _buildPartUrls(item);
    _currentPartIndex = 0;
    _partOffset       = Duration.zero;
    _partDurations.clear();
    _preloadReady             = false;
    _lastSavedPositionSeconds = 0;
    _pendingSeekAfterLoad     = null;
    _knownTotalDuration = item.duration != null
        ? Duration(seconds: item.duration!)
        : null;

    mediaItem.add(_playableToMediaItem(item));
    debugPrint('[AudioHandler] Loading "${item.title}" — ${_partUrls.length} part(s)'
        '${resumePosition ? ' (resume mode ON)' : ''}');

    Duration resumeAt = Duration.zero;
    if (resumePosition) {
      final savedSeconds = PlaybackPositionService.get(item.id);
      if (savedSeconds != null && savedSeconds > 5) {
        resumeAt = Duration(seconds: savedSeconds);
        debugPrint('[AudioHandler] Will resume "${item.title}" at ${savedSeconds}s');
      }
    }

    await _loadPartAndPlay(0, startAt: resumeAt);

    _broadcastCritical();
    _scheduleNextItemPreload();

    // FIX 4: Near end of queue? Pre-warm next album in background.
    final isLastInQueue = _currentQueueIndex >= _playableQueue.length - 1;
    if (isLastInQueue && _loopMode == ja.LoopMode.off) {
      Future.delayed(const Duration(seconds: 3), _preloadNextAlbumTrack);
    }
  }

  // ── Stream re-attachment ───────────────────────────────────────────────────

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

      if (dur != null && dur > Duration.zero && _pendingSeekAfterLoad != null) {
        final seekTo = _pendingSeekAfterLoad!;
        _pendingSeekAfterLoad = null;

        if (seekTo < dur) {
          debugPrint('[AudioHandler] Stream ready — executing pending seek to ${seekTo.inSeconds}s');
          _player.seek(seekTo).catchError((e) {
            debugPrint('[AudioHandler] Pending seek failed: $e');
          });
        }
      }

      if (!_durationController.isClosed) {
        _durationController.add(_unifiedDuration);
      }

      // FIX 2: Reschedule preload now that we know duration.
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

  // ── Broadcast throttling ───────────────────────────────────────────────────

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

  // ── Position helpers ───────────────────────────────────────────────────────

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
    if (_pendingSeekAfterLoad != null) return;
    final posSeconds = _unifiedPosition.inSeconds;
    if ((posSeconds - _lastSavedPositionSeconds).abs() < _saveIntervalSeconds) return;
    _lastSavedPositionSeconds = posSeconds;
    PlaybackPositionService.save(item.id, posSeconds, totalSeconds: item.duration);
  }

  void _savePositionNow() {
    final item = _currentQueueIndex < _playableQueue.length
        ? _playableQueue[_currentQueueIndex]
        : null;
    if (item == null) return;
    if (_pendingSeekAfterLoad != null) return;
    PlaybackPositionService.save(item.id, _unifiedPosition.inSeconds, totalSeconds: item.duration);
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

  // ── Public API ─────────────────────────────────────────────────────────────

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
    _pendingSeekAfterLoad = null;

    // FIX 3: Do NOT cancel next-item preload on seek — user is just scrubbing
    // within the current track; the preloaded next item is still valid.

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
          _pendingSeekAfterLoad = remaining;
          await _refreshAndRetry(_partUrls[targetPart]);
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
    // FIX 3: Only cancel preload if we're actually changing which item is preloaded.
    final nextIdx = _nextQueueIndex();
    if (nextIdx != null && _nextItemPreloadIndex != nextIdx) {
      _cancelNextItemPreload();
    }

    if (_currentQueueIndex < _playableQueue.length - 1) {
      await _playItemAtQueueIndex(_currentQueueIndex + 1);
    } else if (_loopMode == ja.LoopMode.all && _playableQueue.isNotEmpty) {
      await _playItemAtQueueIndex(0);
    } else {
      debugPrint('[AudioHandler] skipToNext: queue end — invoking onQueueExhausted');
      if (_nextAlbumPreloaded) {
        await _doGaplessAlbumAdvance();
      } else {
        onQueueExhausted?.call();
      }
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
    // Don't cancel preload on loop mode change — the next item might still be valid.
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
    await _nextAlbumPlayer.dispose();
  }
}