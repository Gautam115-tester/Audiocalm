// lib/features/player/services/playback_position_service.dart
//
// Persists per-episode / per-song playback positions so the UI can show
// "Remaining: 7m 32s" and resume from where the user left off.
//
// DESIGN:
//   • Positions saved to Hive box 'playback_positions_box' (new box).
//   • Key format: "pos_<mediaId>"  →  value: int (seconds into the content).
//   • Written every ~5 s while playing (throttled) AND on pause/stop.
//   • Cleared when the episode/song reaches the last ~30 s (considered "done").
//   • completedEpisodesProvider.markCompleted() is also called on completion.
//   • Works offline — purely Hive-based, zero network calls.
//
// USAGE (in audio_player_provider.dart):
//   PlaybackPositionService.save(mediaId, positionSeconds);
//   PlaybackPositionService.clear(mediaId);
//   int? pos = PlaybackPositionService.get(mediaId);
//   int? remaining = PlaybackPositionService.remaining(mediaId, durationSeconds);

import 'package:hive_flutter/hive_flutter.dart';

const _kBoxName  = 'playback_positions_box';
const _kPrefix   = 'pos_';
// If less than this many seconds remain, treat as "done" and clear position.
const _kDoneThresholdSeconds = 30;

class PlaybackPositionService {
  PlaybackPositionService._();

  // ── Box init ───────────────────────────────────────────────────────────────
  // Called from main.dart during Hive.openBox() sequence.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(_kBoxName)) {
      await Hive.openBox(_kBoxName);
    }
  }

  static Box get _box => Hive.box(_kBoxName);

  // ── Save ───────────────────────────────────────────────────────────────────
  /// Persist [positionSeconds] for [mediaId].
  /// Pass [totalSeconds] to auto-clear when near the end.
  static void save(String mediaId, int positionSeconds, {int? totalSeconds}) {
    if (positionSeconds <= 0) return;

    // Auto-clear if within the "done" threshold of the end.
    if (totalSeconds != null && totalSeconds > 0) {
      final remaining = totalSeconds - positionSeconds;
      if (remaining <= _kDoneThresholdSeconds) {
        clear(mediaId);
        return;
      }
    }

    try {
      _box.put('$_kPrefix$mediaId', positionSeconds);
    } catch (_) {}
  }

  // ── Get ────────────────────────────────────────────────────────────────────
  /// Returns the last saved position in seconds, or null if none / cleared.
  static int? get(String mediaId) {
    try {
      final v = _box.get('$_kPrefix$mediaId');
      if (v is int && v > 0) return v;
    } catch (_) {}
    return null;
  }

  // ── Remaining ──────────────────────────────────────────────────────────────
  /// Returns seconds remaining (total − saved position), or null if unknown.
  static int? remaining(String mediaId, int? totalSeconds) {
    final pos = get(mediaId);
    if (pos == null || totalSeconds == null || totalSeconds <= 0) return null;
    final r = totalSeconds - pos;
    return r > 0 ? r : null;
  }

  // ── Clear ──────────────────────────────────────────────────────────────────
  /// Remove the saved position (episode completed or explicitly reset).
  static void clear(String mediaId) {
    try {
      _box.delete('$_kPrefix$mediaId');
    } catch (_) {}
  }

  // ── Format ─────────────────────────────────────────────────────────────────
  /// Returns a human-readable remaining string, e.g. "7m 32s" or "1h 3m".
  static String? formatRemaining(String mediaId, int? totalSeconds) {
    final secs = remaining(mediaId, totalSeconds);
    if (secs == null) return null;
    return _format(secs);
  }

  static String _format(int seconds) {
    if (seconds <= 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return m > 0 ? '${h}h ${m}m' : '${h}h';
    }
    if (m > 0) {
      return s > 0 ? '${m}m ${s}s' : '${m}m';
    }
    return '${s}s';
  }
}