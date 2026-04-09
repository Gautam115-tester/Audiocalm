// lib/features/player/services/multi_part_resolver.dart
//
// Helpers for building just_audio sources from multi-part audio files.
// Stateless — no network calls; just source construction and position maths.

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

// ── Data types ────────────────────────────────────────────────────────────────

/// A single audio part with its stream URL and optional duration hint.
class AudioPart {
  final String partId;        // e.g. "episode-id_part01"
  final String streamUrl;
  final Duration? knownDuration;

  const AudioPart({
    required this.partId,
    required this.streamUrl,
    this.knownDuration,
  });
}

/// Result from resolving a content item — either single or multi-part.
class ResolvedAudioSource {
  final ja.AudioSource source;
  final bool isMultiPart;
  final int partCount;
  final Duration? totalDuration; // sum of known part durations, if available

  const ResolvedAudioSource({
    required this.source,
    this.isMultiPart = false,
    this.partCount = 1,
    this.totalDuration,
  });
}

// ── MultiPartResolver ─────────────────────────────────────────────────────────

class MultiPartResolver {
  static const String _partSuffix = '_part';

  // ── Part ID helpers ───────────────────────────────────────────────────────

  /// Build part IDs from a known count (used when metadata is available).
  static List<String> buildPartIds(String baseId, int partCount) {
    return List.generate(
      partCount,
      (i) => '$baseId$_partSuffix${(i + 1).toString().padLeft(2, '0')}',
    );
  }

  /// Returns true if a content ID is itself a part (contains _part suffix).
  static bool isPart(String contentId) => contentId.contains(_partSuffix);

  /// Extract the base ID from a part ID.
  static String baseIdFromPart(String partId) {
    final idx = partId.lastIndexOf(_partSuffix);
    return idx >= 0 ? partId.substring(0, idx) : partId;
  }

  /// Extract the 1-based part number from a part ID.
  static int? partNumberFromId(String partId) {
    final idx = partId.lastIndexOf(_partSuffix);
    if (idx < 0) return null;
    return int.tryParse(partId.substring(idx + _partSuffix.length));
  }

  // ── Source builders ───────────────────────────────────────────────────────

  /// Build a seamless [ConcatenatingAudioSource] from a list of [AudioPart]s.
  /// Uses standard [AudioSource.uri] for each part.
  static ja.ConcatenatingAudioSource buildConcatenatingSource(
    List<AudioPart> parts,
  ) {
    assert(parts.isNotEmpty, 'Parts list must not be empty');
    return ja.ConcatenatingAudioSource(
      useLazyPreparation: true, // next part prepares while current plays
      shuffleOrder: ja.DefaultShuffleOrder(),
      children: parts.map((p) {
        return ja.AudioSource.uri(
          Uri.parse(p.streamUrl),
          tag: p.partId,
        );
      }).toList(),
    );
  }

  /// Build with [LockCachingAudioSource] for better seek & prefetch behaviour.
  /// Prefer this for downloaded / slow network scenarios.
  static ja.ConcatenatingAudioSource buildCachingConcatenatingSource(
    List<AudioPart> parts,
  ) {
    assert(parts.isNotEmpty, 'Parts list must not be empty');
    return ja.ConcatenatingAudioSource(
      useLazyPreparation: true,
      shuffleOrder: ja.DefaultShuffleOrder(),
      children: parts.map((p) {
        return ja.LockCachingAudioSource(
          Uri.parse(p.streamUrl),
          tag: p.partId,
          headers: const {
            'Connection': 'keep-alive',
            'Accept': '*/*',
          },
        );
      }).toList(),
    );
  }

  /// Build a single-part source (convenience wrapper).
  static ja.AudioSource buildSingleSource(AudioPart part) {
    return ja.AudioSource.uri(
      Uri.parse(part.streamUrl),
      tag: part.partId,
    );
  }

  /// Choose the right source type automatically:
  /// - 1 part  → simple UriAudioSource
  /// - N parts → ConcatenatingAudioSource
  static ResolvedAudioSource resolve(List<AudioPart> parts) {
    assert(parts.isNotEmpty);

    if (parts.length == 1) {
      return ResolvedAudioSource(
        source: buildSingleSource(parts.first),
        isMultiPart: false,
        partCount: 1,
        totalDuration: parts.first.knownDuration,
      );
    }

    Duration? total;
    if (parts.every((p) => p.knownDuration != null)) {
      total = parts.fold(
          Duration.zero, (acc, p) => acc + p.knownDuration!);
    }

    return ResolvedAudioSource(
      source: buildConcatenatingSource(parts),
      isMultiPart: true,
      partCount: parts.length,
      totalDuration: total,
    );
  }
}

// ── MultiPartPositionTracker ──────────────────────────────────────────────────

/// Tracks logical playback position across all parts so a single unified
/// seekbar and total duration can be shown.
class MultiPartPositionTracker {
  final List<Duration> _partDurations;

  MultiPartPositionTracker(this._partDurations);

  /// Total duration across all parts.
  Duration get totalDuration => _partDurations.fold(
        Duration.zero,
        (acc, d) => acc + d,
      );

  /// Offset (start time) of a given part index in the unified timeline.
  Duration offsetForPart(int partIndex) {
    Duration offset = Duration.zero;
    for (int i = 0; i < partIndex && i < _partDurations.length; i++) {
      offset += _partDurations[i];
    }
    return offset;
  }

  /// Convert a unified position to (partIndex, positionWithinPart).
  ({int partIndex, Duration positionInPart}) splitPosition(Duration unified) {
    Duration remaining = unified;
    for (int i = 0; i < _partDurations.length; i++) {
      if (remaining <= _partDurations[i]) {
        return (partIndex: i, positionInPart: remaining);
      }
      remaining -= _partDurations[i];
    }
    // Clamp to end of last part
    return (
      partIndex: _partDurations.length - 1,
      positionInPart: _partDurations.last,
    );
  }

  /// Convert (partIndex, positionWithinPart) to unified position.
  Duration unifiedPosition(int partIndex, Duration positionInPart) {
    return offsetForPart(partIndex) + positionInPart;
  }

  /// Return a new tracker with one part's duration updated.
  MultiPartPositionTracker withUpdatedDuration(
      int partIndex, Duration duration) {
    final updated = List<Duration>.from(_partDurations);
    if (partIndex < updated.length) {
      updated[partIndex] = duration;
    }
    return MultiPartPositionTracker(updated);
  }
}
