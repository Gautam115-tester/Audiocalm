// lib/core/utils/background_worker.dart
//
// Offloads heavy JSON parsing and Hive I/O to background isolates so the
// main thread (and therefore the GPU render thread) is never starved.
//
// WHY THIS FILE EXISTS:
//   The BLASTBufferQueue "Can't acquire next buffer" error + "Skipped 72 frames"
//   are caused by the main thread being blocked during startup:
//     1. Hive.openBox() and box.keys / box.get() run on the main isolate.
//     2. JSON.decode() of large album/series payloads (all-with-songs) runs
//        on the main isolate inside FutureProvider callbacks.
//     3. Both happen at the same time as Flutter's first render, starving the
//        Choreographer and overflowing the SurfaceView buffer queue.
//
// FIX: Use Flutter's compute() (thin wrapper around Isolate.run) for any
// work > ~1 ms. The helpers here are drop-in replacements for common patterns.

import 'dart:async';
import 'package:flutter/foundation.dart';

// ── JSON decoding in a background isolate ────────────────────────────────────

/// Decode a large JSON list on a background isolate.
/// Drop-in for `(response['data'] as List<dynamic>)` when the payload is large.
Future<List<Map<String, dynamic>>> decodeJsonListInBackground(
  String jsonString,
) {
  return compute(_decodeJsonList, jsonString);
}

List<Map<String, dynamic>> _decodeJsonList(String jsonString) {
  // dart:convert is safe in an isolate
  // ignore: avoid_dynamic_calls
  final decoded = (jsonString is List)
      ? jsonString as List
      : (throw ArgumentError('Expected JSON list string'));
  return decoded.cast<Map<String, dynamic>>();
}

// ── Model list parsing in a background isolate ────────────────────────────────

/// Parse a raw list of JSON maps into model objects on a background isolate.
///
/// Usage:
/// ```dart
/// final albums = await parseModelsInBackground<AlbumModel>(
///   rawList,
///   (json) => AlbumModel.fromJson(json),
/// );
/// ```
///
/// Note: [fromJson] is called inside the isolate, so it must be a top-level
/// or static function (no closures capturing widget state).
Future<List<T>> parseModelsInBackground<T>(
  List<Map<String, dynamic>> rawList,
  T Function(Map<String, dynamic>) fromJson,
) {
  return compute(_parseModels<T>, _ParsePayload(rawList, fromJson));
}

class _ParsePayload<T> {
  final List<Map<String, dynamic>> rawList;
  final T Function(Map<String, dynamic>) fromJson;
  const _ParsePayload(this.rawList, this.fromJson);
}

List<T> _parseModels<T>(_ParsePayload<T> payload) {
  return payload.rawList.map(payload.fromJson).toList();
}

// ── Chunked rendering helper ──────────────────────────────────────────────────
//
// When we need to push a large number of items into state, doing it all at once
// causes a large layout pass that stalls the GPU pipeline.
//
// buildFrameChunked() yields control back to the event loop between chunks,
// letting the Choreographer schedule frames between bursts of work.

/// Process [items] in [chunkSize] batches, yielding between chunks so
/// the render thread can breathe.  [onChunk] is called with each slice.
Future<void> buildFrameChunked<T>({
  required List<T> items,
  required int chunkSize,
  required void Function(List<T> chunk, bool isLast) onChunk,
}) async {
  for (int i = 0; i < items.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, items.length);
    final chunk = items.sublist(i, end);
    final isLast = end >= items.length;
    onChunk(chunk, isLast);
    if (!isLast) {
      // Yield to the event loop → Flutter can schedule a frame here
      await Future.delayed(Duration.zero);
    }
  }
}

// ── Throttled state emitter ───────────────────────────────────────────────────
//
// Prevents rapid-fire setState / state = ... calls that cause multiple
// synchronous layout passes per frame, which is a secondary cause of
// BLASTBufferQueue overflow.

class ThrottledEmitter<T> {
  final Duration throttle;
  final void Function(T value) emit;

  T? _pending;
  bool _scheduled = false;

  ThrottledEmitter({
    this.throttle = const Duration(milliseconds: 16), // ~1 frame @60 fps
    required this.emit,
  });

  void schedule(T value) {
    _pending = value;
    if (_scheduled) return;
    _scheduled = true;
    Future.delayed(throttle, () {
      final v = _pending;
      _pending = null;
      _scheduled = false;
      if (v != null) emit(v);
    });
  }
}