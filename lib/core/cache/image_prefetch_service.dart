// lib/core/cache/image_prefetch_service.dart
//
// Warms the CachedNetworkImage in-memory cache for cover art so images
// appear INSTANTLY when the user scrolls — no per-item loading flash.
//
// Strategy:
//   Phase 1 (immediate): prefetch first 6 visible covers at full display size
//   Phase 2 (deferred):  prefetch remaining covers at thumbnail size in background
//
// Called from calm_music_provider and calm_stories_provider after data parses.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

class ImagePrefetchService {
  ImagePrefetchService._();

  static const int _kPhase1Count = 8;
  static const int _kThumbnailWidth = 300;

  /// Prefetch cover URLs extracted from album/series data.
  /// [urls] should be ordered by display priority (first = most important).
  static Future<void> prefetchCovers(
    BuildContext context,
    List<String?> urls,
  ) async {
    final valid = urls.whereType<String>().where((u) => u.isNotEmpty).toList();
    if (valid.isEmpty) return;

    final phase1 = valid.take(_kPhase1Count).toList();
    final phase2 = valid.skip(_kPhase1Count).toList();

    // Phase 1: priority covers — precache at display size immediately
    await Future.wait(
      phase1.map((url) => _precache(context, url, width: _kThumbnailWidth)),
      eagerError: false,
    );

    // Phase 2: remaining covers — precache lazily in background
    if (phase2.isNotEmpty) {
      Future.delayed(const Duration(milliseconds: 300), () {
        for (final url in phase2) {
          _precache(context, url, width: _kThumbnailWidth).catchError((_) {});
        }
      });
    }
  }

  static Future<void> _precache(
    BuildContext context,
    String url, {
    int? width,
    int? height,
  }) async {
    try {
      await precacheImage(
        CachedNetworkImageProvider(
          url,
          maxWidth: width,
          maxHeight: height,
        ),
        context,
      );
    } catch (_) {
      // Silently ignore — network may be slow, image may 404
    }
  }
}