// lib/features/player/services/multi_part_url_service.dart
//
// Resolves audio part URLs by querying the /parts backend endpoint.
// Replaces the old HEAD-probing approach (which caused 8s timeout delays).

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/di/providers.dart';
import 'multi_part_resolver.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

final multiPartUrlServiceProvider = Provider<MultiPartUrlService>((ref) {
  // dioClientProvider returns DioClient (wrapper); we use its .dio getter
  // for raw Dio access, or call .get() directly on the wrapper.
  return MultiPartUrlService(ref.read(dioClientProvider));
});

// ── Service ───────────────────────────────────────────────────────────────────

class MultiPartUrlService {
  // DioClient is the project's typed wrapper around Dio.
  // We use it directly rather than raw Dio so all interceptors are applied.
  final dynamic _client; // DioClient — typed as dynamic to avoid circular import

  MultiPartUrlService(this._client);

  /// Resolve audio parts for a content item via the /parts API endpoint.
  ///
  /// [baseId]      — the episode or song ID (e.g. "abc-123")
  /// [contentType] — 'episodes' or 'songs'
  ///
  /// Returns a list of [AudioPart] objects, one per file part.
  /// Falls back gracefully to a single-part stream on any error.
  Future<List<AudioPart>> resolveAudioParts({
    required String baseId,
    required String contentType, // 'episodes' | 'songs'
  }) async {
    // Endpoint: /api/episodes/:id/parts  or  /api/songs/:id/parts
    final partsPath = '/api/$contentType/$baseId/parts';

    try {
      // DioClient.get<T> returns response.data directly
      final data = await _client.get<Map<String, dynamic>>(partsPath);

      final partsList = data['parts'] as List<dynamic>? ?? [];

      if (partsList.isEmpty) {
        debugPrint('[MultiPart] /parts returned empty → single file fallback');
        return [_singlePart(contentType, baseId)];
      }

      final parts = partsList.map((p) {
        final map = p as Map<String, dynamic>;
        final durationSec = map['durationSeconds'] as int?;
        return AudioPart(
          partId: map['id'] as String? ?? baseId,
          streamUrl: map['streamUrl'] as String,
          knownDuration:
              durationSec != null ? Duration(seconds: durationSec) : null,
        );
      }).toList();

      final isMultiPart = data['isMultiPart'] == true;
      debugPrint(
          '[MultiPart] $baseId → ${parts.length} part(s), multiPart=$isMultiPart');
      return parts;
    } catch (e) {
      // Any network / parse error → fall back to single file
      debugPrint('[MultiPart] /parts error: $e → single file fallback');
      return [_singlePart(contentType, baseId)];
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Build a single-part [AudioPart] using the project's ApiConstants.
  AudioPart _singlePart(String contentType, String id) {
    return AudioPart(
      partId: id,
      streamUrl: _streamUrl(contentType, id),
    );
  }

  /// Stream URL pattern: /api/episodes/:id/stream  or  /api/songs/:id/stream
  String _streamUrl(String contentType, String id) {
    if (contentType == 'episodes') {
      return '${ApiConstants.baseUrl}${ApiConstants.episodeStream(id)}';
    }
    return '${ApiConstants.baseUrl}${ApiConstants.songStream(id)}';
  }
}

// ── Convenience extension ─────────────────────────────────────────────────────

extension MultiPartHelpers on MultiPartUrlService {
  /// Build parts from a known count without hitting the network.
  /// Useful when partCount is already known from the model (e.g. song.partCount).
  List<AudioPart> buildPartsFromCount({
    required String baseId,
    required String contentType,
    required int partCount,
  }) {
    if (partCount <= 1) {
      return [
        AudioPart(
          partId: baseId,
          streamUrl: _streamUrl(contentType, baseId),
        )
      ];
    }
    return List.generate(partCount, (i) {
      final partNum = (i + 1).toString().padLeft(2, '0');
      // Backend uses ?part=N query param, not separate IDs
      final streamUrl = '${_streamUrl(contentType, baseId)}?part=${i + 1}';
      return AudioPart(
        partId: '${baseId}_part$partNum',
        streamUrl: streamUrl,
      );
    });
  }

  String _streamUrl(String contentType, String id) {
    if (contentType == 'episodes') {
      return '${ApiConstants.baseUrl}${ApiConstants.episodeStream(id)}';
    }
    return '${ApiConstants.baseUrl}${ApiConstants.songStream(id)}';
  }
}
