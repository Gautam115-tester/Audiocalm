// lib/features/player/services/multi_part_url_service.dart
//
// Resolves audio part URLs by querying the /parts backend endpoint.
// The backend returns /stream?part=N URLs which the backend then
// 302-redirects to Telegram CDN URLs. just_audio follows those
// redirects transparently.
//
// CHANGES:
// 1. buildPartsFromCount() now produces URLs that work with the redirect
//    architecture — no behaviour change needed since the URL format is the same.
// 2. Added buildRefreshUrl() — appends ?refresh=1 to force server-side
//    URL cache eviction when a URL has expired.
// 3. resolveAudioParts() unchanged in API surface.
//
// Backend response shape for /api/episodes/:id/parts and /api/songs/:id/parts:
// {
//   "success": true,
//   "id": "...",
//   "title": "...",
//   "isMultiPart": true,
//   "partCount": 2,
//   "duration": 3600,
//   "parts": [
//     { "partNumber": 1, "streamUrl": "...", "downloadUrl": "..." },
//     { "partNumber": 2, "streamUrl": "...", "downloadUrl": "..." }
//   ]
// }

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
  final dynamic _client; // DioClient — dynamic to avoid circular import

  MultiPartUrlService(this._client);

  // ── buildStreamUrl ────────────────────────────────────────────────────────

  /// Returns the backend stream URL for a content item (no network call).
  /// The backend will 302-redirect this to Telegram CDN when requested.
  String buildStreamUrl(String contentType, String id) {
    if (contentType == 'episodes') {
      return '${ApiConstants.baseUrl}${ApiConstants.episodeStream(id)}';
    }
    return '${ApiConstants.baseUrl}${ApiConstants.songStream(id)}';
  }

  /// Returns a stream URL with ?refresh=1 appended.
  /// Used to force the backend to evict its URL cache and get a fresh
  /// Telegram signed URL when the previous one has expired.
  String buildRefreshUrl(String contentType, String id, {int part = 1}) {
    final base = buildStreamUrl(contentType, id);
    if (part > 1) {
      return '$base?part=$part&refresh=1';
    }
    return '$base?refresh=1';
  }

  // ── resolveAudioParts ─────────────────────────────────────────────────────

  /// Resolve audio parts for a content item via the /parts API endpoint.
  Future<List<AudioPart>> resolveAudioParts({
    required String baseId,
    required String contentType,
    int knownPartCount = 1,
  }) async {
    if (knownPartCount <= 1) {
      return [_singlePart(contentType, baseId)];
    }

    final partsPath = '/api/$contentType/$baseId/parts';

    try {
      final data = await _client.get<Map<String, dynamic>>(partsPath);
      final partsList = data['parts'] as List<dynamic>? ?? [];

      if (partsList.isEmpty) {
        debugPrint('[MultiPart] /parts returned empty → ?part=N fallback');
        return _buildQueryParamParts(contentType, baseId, knownPartCount);
      }

      final parts = partsList.map((p) {
        final map       = p as Map<String, dynamic>;
        final streamUrl = map['streamUrl'] as String? ?? '';
        if (streamUrl.isEmpty) {
          throw FormatException('part missing streamUrl: $map');
        }
        return AudioPart(
          partId:    '${baseId}_part${map['partNumber'] ?? ''}',
          streamUrl: streamUrl,
          knownDuration: null, // backend doesn't provide per-part duration
        );
      }).toList();

      debugPrint('[MultiPart] $baseId → ${parts.length} parts from /parts');
      return parts;
    } catch (e) {
      debugPrint('[MultiPart] /parts error for $baseId: $e → fallback');
      return _buildQueryParamParts(contentType, baseId, knownPartCount);
    }
  }

  // ── buildPartsFromCount ───────────────────────────────────────────────────

  /// Build parts from a known count WITHOUT a network call.
  /// Uses ?part=N URLs that the backend redirects to Telegram CDN.
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
      partId:    id,
      streamUrl: buildStreamUrl(contentType, id),
    );
  }

  List<AudioPart> _buildQueryParamParts(
      String contentType, String baseId, int partCount) {
    return List.generate(partCount, (i) {
      final partNum = i + 1;
      return AudioPart(
        partId:    '${baseId}_part${partNum.toString().padLeft(2, '0')}',
        // Backend will 302-redirect this to Telegram CDN
        streamUrl: '${buildStreamUrl(contentType, baseId)}?part=$partNum',
      );
    });
  }
}