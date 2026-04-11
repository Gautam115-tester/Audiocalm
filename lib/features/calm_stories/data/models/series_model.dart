// lib/features/calm_stories/data/models/series_model.dart
//
// CHANGES:
// 1. Added totalDurationSeconds field (sum of all episode durations, computed
//    in the provider from the live episodes array).
// 2. Added formattedTotalDuration helper ("6h 32m", "45m", etc.).
// 3. episodeCount is now expected to be the live count injected by the provider
//    (derived from episodes.length, not the stale DB field).

class SeriesModel {
  final String  id;
  final String  title;
  final String? description;
  final String? coverUrl;
  final bool    isActive;
  final int     episodeCount;          // live count, injected by provider
  final int     totalDurationSeconds;  // sum of all episode durations in seconds
  final DateTime createdAt;

  const SeriesModel({
    required this.id,
    required this.title,
    this.description,
    this.coverUrl,
    required this.isActive,
    this.episodeCount = 0,
    this.totalDurationSeconds = 0,
    required this.createdAt,
  });

  factory SeriesModel.fromJson(Map<String, dynamic> json) {
    return SeriesModel(
      id:                   json['id']?.toString() ?? '',
      title:                json['title']?.toString() ?? '',
      description:          json['description']?.toString(),
      coverUrl:             json['coverUrl']?.toString(),
      isActive:             json['isActive'] as bool? ?? true,
      episodeCount:         json['episodeCount'] as int? ?? 0,
      totalDurationSeconds: json['totalDurationSeconds'] as int? ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  /// Human-readable total duration, e.g. "6h 32m", "45m", "" if unknown.
  String get formattedTotalDuration {
    if (totalDurationSeconds <= 0) return '';
    final h = totalDurationSeconds ~/ 3600;
    final m = (totalDurationSeconds % 3600) ~/ 60;
    if (h > 0 && m > 0) return '${h}h ${m}m';
    if (h > 0) return '${h}h';
    if (m > 0) return '${m}m';
    return '<1m';
  }
}