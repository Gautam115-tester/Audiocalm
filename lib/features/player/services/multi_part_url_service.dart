// lib/features/player/services/multi_part_url_service.dart
//
// Resolves audio part URLs by querying the /parts backend endpoint.
//
// Backend response shape for /api/episodes/:id/parts and /api/songs/:id/parts:
// {
//   "success": true,
//   "id": "...",
//   "title": "...",
//   "isMultiPart": true,
//   "partCount": 2,
//   "duration": 3600,          ← total seconds (may be null)
//   "parts": [
//     { "partNumber": 1, "streamUrl": "...", "downloadUrl": "..." },
//     { "partNumber": 2, "streamUrl": "...", "downloadUrl": "..." }
//   ]
// }
//
// NOTE: The backend does NOT include per-part durationSeconds — only the
// episode/song-level `duration` (total seconds). We therefore leave
// AudioPart.knownDuration null for each part; the player reads the real
// duration from just_audio once buffering begins.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/api_constants.dart';
import '../../../../core/di/providers.dart';
import 'multi_part_resolver.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

final multiPartUrlServiceProvider = Provider<MultiPartUrlService>((ref) {
  return MultiPartUrlService(ref.read(dioClientProvider));
});

// ── Service ───────────────────────────────────────────────────────────────────

class MultiPartUrlService {
  final dynamic _client; // DioClient — typed as dynamic to avoid circular import

  MultiPartUrlService(this._client);

  // ── buildStreamUrl ────────────────────────────────────────────────────────

  /// Returns the direct stream URL for a content item (no network call).
  /// Used as fallback and for single-part items.
  String buildStreamUrl(String contentType, String id) {
    if (contentType == 'episodes') {
      return '${ApiConstants.baseUrl}${ApiConstants.episodeStream(id)}';
    }
    return '${ApiConstants.baseUrl}${ApiConstants.songStream(id)}';
  }

  // ── resolveAudioParts ─────────────────────────────────────────────────────

  /// Resolve audio parts for a content item via the /parts API endpoint.
  ///
  /// [baseId]      — the episode or song ID (e.g. "abc-123")
  /// [contentType] — 'episodes' or 'songs'
  /// [knownPartCount] — if > 1 and the /parts call fails, we still build
  ///                    the correct number of ?part=N URLs without a network
  ///                    round-trip (avoids double-failure).
  ///
  /// Returns a list of [AudioPart] objects, one per file part.
  /// Falls back gracefully to a single-part stream on any error.
  Future<List<AudioPart>> resolveAudioParts({
    required String baseId,
    required String contentType, // 'episodes' | 'songs'
    int knownPartCount = 1,
  }) async {
    // Fast path: no need to hit the network for single-part content.
    if (knownPartCount <= 1) {
      return [_singlePart(contentType, baseId)];
    }

    // Endpoint: /api/episodes/:id/parts  or  /api/songs/:id/parts
    final partsPath = '/api/$contentType/$baseId/parts';

    try {
      final data = await _client.get<Map<String, dynamic>>(partsPath);

      final partsList = data['parts'] as List<dynamic>? ?? [];

      if (partsList.isEmpty) {
        debugPrint('[MultiPart] /parts returned empty list → ?part=N fallback');
        return _buildQueryParamParts(contentType, baseId, knownPartCount);
      }

      final parts = partsList.map((p) {
        final map = p as Map<String, dynamic>;
        // Backend field is 'streamUrl', not 'url'.
        final streamUrl = map['streamUrl'] as String? ?? '';
        if (streamUrl.isEmpty) {
          throw FormatException('part missing streamUrl: $map');
        }
        // Backend does not provide per-part duration — leave null so
        // just_audio resolves it from the stream itself.
        return AudioPart(
          partId: '${baseId}_part${map['partNumber'] ?? ''}',
          streamUrl: streamUrl,
          knownDuration: null,
        );
      }).toList();

      debugPrint(
          '[MultiPart] $baseId → ${parts.length} part(s) from /parts endpoint');
      return parts;
    } catch (e) {
      debugPrint('[MultiPart] /parts error for $baseId: $e → ?part=N fallback');
      return _buildQueryParamParts(contentType, baseId, knownPartCount);
    }
  }

  // ── buildPartsFromCount ───────────────────────────────────────────────────

  /// Build parts from a known count WITHOUT a network call.
  /// Uses the ?part=N query parameter pattern the backend already supports.
  List<AudioPart> buildPartsFromCount({
    required String baseId,
    required String contentType,
    required int partCount,
  }) {
    if (partCount <= 1) {
      return [_singlePart(contentType, baseId)];
    }
    return _buildQueryParamParts(contentType, baseId, partCount);
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  AudioPart _singlePart(String contentType, String id) {
    return AudioPart(
      partId: id,
      streamUrl: buildStreamUrl(contentType, id),
    );
  }

  /// Builds ?part=1, ?part=2 … ?part=N URLs — exactly what the backend
  /// expects when streaming multi-part files.
  List<AudioPart> _buildQueryParamParts(
      String contentType, String baseId, int partCount) {
    return List.generate(partCount, (i) {
      final partNum = i + 1;
      return AudioPart(
        partId: '${baseId}_part${partNum.toString().padLeft(2, '0')}',
        streamUrl: '${buildStreamUrl(contentType, baseId)}?part=$partNum',
      );
    });
  }
}