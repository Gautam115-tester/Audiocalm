// lib/features/player/services/smart_prefetch_manager.dart
//
// SMART PREFETCH MANAGER
// ======================
// Handles intelligent pre-loading of audio content with:
//  1. Adaptive quality selection based on connection speed
//  2. Background prefetch of next N items in queue
//  3. Bandwidth estimation from download speed
//  4. Priority queue (current > next > upcoming)
//  5. Cache management to avoid redundant fetches
//  6. Slow network detection + fallback strategy

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';

enum NetworkQuality { fast, medium, slow, unknown }
enum PrefetchPriority { critical, high, normal, low }

class PrefetchEntry {
  final String id;
  final String url;
  final PrefetchPriority priority;
  final DateTime queuedAt;
  ja.AudioPlayer? player;
  bool isReady = false;
  bool isFailed = false;
  int retryCount = 0;

  PrefetchEntry({
    required this.id,
    required this.url,
    required this.priority,
  }) : queuedAt = DateTime.now();
}

class BandwidthSample {
  final double bytesPerSecond;
  final DateTime recordedAt;
  BandwidthSample(this.bytesPerSecond) : recordedAt = DateTime.now();
}

class SmartPrefetchManager {
  static final SmartPrefetchManager _instance = SmartPrefetchManager._();
  factory SmartPrefetchManager() => _instance;
  SmartPrefetchManager._();

  // ── Configuration ──────────────────────────────────────────────────────────

  static const int _maxConcurrentPrefetches = 2;
  static const int _maxQueueSize = 8;
  static const int _maxRetries = 2;
  static const Duration _prefetchTimeout = Duration(seconds: 25);
  static const Duration _slowNetworkThreshold = Duration(seconds: 8);

  // 8 MB avg music file — start prefetch when 60s remain in current track
  static const int _prefetchLeadSeconds = 60;
  static const int _avgFileSizeMB = 8;

  // ── State ──────────────────────────────────────────────────────────────────

  final Map<String, PrefetchEntry> _cache = {};
  final List<String> _queue = [];
  int _activePrefetches = 0;
  NetworkQuality _networkQuality = NetworkQuality.unknown;
  final List<BandwidthSample> _bandwidthSamples = [];
  Timer? _bandwidthCheckTimer;
  bool _disposed = false;

  // Callbacks
  void Function(String id)? onPrefetchReady;
  void Function(String id, String error)? onPrefetchFailed;
  void Function(NetworkQuality quality)? onNetworkQualityChanged;

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Initialize and start bandwidth monitoring
  void init() {
    _startBandwidthMonitoring();
    debugPrint('[SmartPrefetch] Initialized');
  }

  /// Queue a URL for prefetching with given priority
  Future<void> prefetch({
    required String id,
    required String url,
    PrefetchPriority priority = PrefetchPriority.normal,
  }) async {
    if (_disposed) return;
    if (_cache.containsKey(id) && (_cache[id]!.isReady || _cache[id]!.retryCount >= _maxRetries)) return;

    // Remove if already queued (re-prioritize)
    _queue.remove(id);

    final entry = PrefetchEntry(id: id, url: url, priority: priority);
    _cache[id] = entry;

    // Insert by priority
    int insertIdx = _queue.length;
    for (int i = 0; i < _queue.length; i++) {
      final existing = _cache[_queue[i]];
      if (existing != null && existing.priority.index > priority.index) {
        insertIdx = i;
        break;
      }
    }
    _queue.insert(insertIdx, id);

    // Trim queue to max size (drop lowest priority)
    while (_queue.length > _maxQueueSize) {
      final dropped = _queue.removeLast();
      _cache[dropped]?.player?.dispose();
      _cache.remove(dropped);
    }

    _processQueue();
  }

  /// Queue multiple URLs at once (smart batch prefetch)
  Future<void> prefetchBatch({
    required List<({String id, String url})> items,
    PrefetchPriority basePriority = PrefetchPriority.normal,
  }) async {
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      // Later items get lower priority
      final priority = i == 0
          ? PrefetchPriority.high
          : i == 1
              ? basePriority
              : PrefetchPriority.low;
      await prefetch(id: item.id, url: item.url, priority: priority);
    }
  }

  /// Check if a URL is already prefetched and ready
  bool isReady(String id) => _cache[id]?.isReady == true;

  /// Get the pre-loaded player for an id (null if not ready)
  ja.AudioPlayer? getPlayer(String id) {
    final entry = _cache[id];
    if (entry?.isReady == true) return entry!.player;
    return null;
  }

  /// Promote an entry to critical priority (e.g., user tapped play)
  void promote(String id) {
    if (!_cache.containsKey(id)) return;
    _cache[id]!.priority == PrefetchPriority.critical;
    _queue.remove(id);
    _queue.insert(0, id);
    _processQueue();
  }

  /// Remove a prefetched item (e.g., it started playing)
  void consume(String id) {
    _queue.remove(id);
    // Don't dispose the player here — caller takes ownership
    _cache.remove(id);
  }

  /// Clear all prefetches
  void clear() {
    for (final entry in _cache.values) {
      entry.player?.dispose();
    }
    _cache.clear();
    _queue.clear();
    _activePrefetches = 0;
  }

  NetworkQuality get networkQuality => _networkQuality;

  double get estimatedBandwidthMbps {
    if (_bandwidthSamples.isEmpty) return 0;
    final recent = _bandwidthSamples
        .where((s) => DateTime.now().difference(s.recordedAt).inSeconds < 30)
        .toList();
    if (recent.isEmpty) return 0;
    final avg = recent.map((s) => s.bytesPerSecond).reduce((a, b) => a + b) / recent.length;
    return avg / (1024 * 1024); // MB/s
  }

  /// Estimated seconds to load an 8MB file at current bandwidth
  Duration get estimatedLoadTime {
    final mbps = estimatedBandwidthMbps;
    if (mbps <= 0) return const Duration(seconds: 15);
    final seconds = _avgFileSizeMB / mbps;
    return Duration(milliseconds: (seconds * 1000).toInt());
  }

  /// Should we prefetch now? (don't prefetch if network is very slow)
  bool get shouldPrefetch {
    if (_networkQuality == NetworkQuality.unknown) return true;
    if (_networkQuality == NetworkQuality.slow) {
      // Only prefetch if we have enough lead time
      return estimatedLoadTime.inSeconds < _prefetchLeadSeconds;
    }
    return true;
  }

  // ── Private: queue processing ──────────────────────────────────────────────

  void _processQueue() {
    while (_activePrefetches < _maxConcurrentPrefetches && _queue.isNotEmpty) {
      final nextId = _queue.removeAt(0);
      final entry = _cache[nextId];
      if (entry == null || entry.isReady || entry.isFailed) continue;
      _doPrefetch(entry);
    }
  }

  Future<void> _doPrefetch(PrefetchEntry entry) async {
    if (_disposed) return;
    _activePrefetches++;

    debugPrint('[SmartPrefetch] Starting prefetch: ${entry.id} (${entry.priority.name})');

    final player = ja.AudioPlayer();
    entry.player = player;

    try {
      final startTime = DateTime.now();
      await player
          .setAudioSource(
            ja.AudioSource.uri(Uri.parse(entry.url)),
            preload: true,
          )
          .timeout(_prefetchTimeout);

      final elapsed = DateTime.now().difference(startTime);
      _recordBandwidthSample(elapsed);

      entry.isReady = true;
      debugPrint('[SmartPrefetch] ✅ Ready: ${entry.id} in ${elapsed.inMilliseconds}ms');
      onPrefetchReady?.call(entry.id);

    } catch (e) {
      entry.retryCount++;
      debugPrint('[SmartPrefetch] ❌ Failed (${entry.retryCount}/$_maxRetries): ${entry.id} — $e');

      if (e.toString().contains('403') || e.toString().contains('401')) {
        // URL expired — try with refresh param
        final refreshed = _appendRefresh(entry.url);
        try {
          await player.setAudioSource(
            ja.AudioSource.uri(Uri.parse(refreshed)),
            preload: true,
          ).timeout(_prefetchTimeout);
          entry.isReady = true;
          onPrefetchReady?.call(entry.id);
        } catch (_) {
          _handlePrefetchFailure(entry, e.toString());
        }
      } else if (entry.retryCount < _maxRetries) {
        // Retry with backoff
        final delay = Duration(seconds: entry.retryCount * 3);
        await Future.delayed(delay);
        if (!_disposed && !entry.isReady) {
          _queue.insert(0, entry.id);
        }
      } else {
        _handlePrefetchFailure(entry, e.toString());
      }
    } finally {
      _activePrefetches = (_activePrefetches - 1).clamp(0, _maxConcurrentPrefetches);
      _processQueue();
    }
  }

  void _handlePrefetchFailure(PrefetchEntry entry, String error) {
    entry.isFailed = true;
    entry.player?.dispose();
    entry.player = null;
    onPrefetchFailed?.call(entry.id, error);
  }

  // ── Bandwidth monitoring ───────────────────────────────────────────────────

  void _startBandwidthMonitoring() {
    _bandwidthCheckTimer?.cancel();
    _bandwidthCheckTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _updateNetworkQuality();
    });
    // Initial check
    Future.delayed(const Duration(seconds: 2), _updateNetworkQuality);
  }

  Future<void> _updateNetworkQuality() async {
    final mbps = estimatedBandwidthMbps;
    NetworkQuality quality;

    if (_bandwidthSamples.isEmpty) {
      quality = NetworkQuality.unknown;
    } else if (mbps >= 2.0) {
      quality = NetworkQuality.fast;
    } else if (mbps >= 0.5) {
      quality = NetworkQuality.medium;
    } else {
      quality = NetworkQuality.slow;
    }

    if (quality != _networkQuality) {
      _networkQuality = quality;
      onNetworkQualityChanged?.call(quality);
      debugPrint('[SmartPrefetch] Network quality: ${quality.name} (${mbps.toStringAsFixed(2)} MB/s)');
    }
  }

  void _recordBandwidthSample(Duration loadTime) {
    if (loadTime.inMilliseconds <= 0) return;
    final bytesPerSecond = (_avgFileSizeMB * 1024 * 1024) / (loadTime.inMilliseconds / 1000);
    _bandwidthSamples.add(BandwidthSample(bytesPerSecond));

    // Keep only last 10 samples
    if (_bandwidthSamples.length > 10) {
      _bandwidthSamples.removeAt(0);
    }

    _updateNetworkQuality();
  }

  String _appendRefresh(String url) {
    return url.contains('?') ? '$url&refresh=1' : '$url?refresh=1';
  }

  void dispose() {
    _disposed = true;
    _bandwidthCheckTimer?.cancel();
    clear();
  }
}