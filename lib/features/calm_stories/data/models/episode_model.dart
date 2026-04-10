// lib/features/calm_stories/data/models/episode_model.dart
//
// MULTI-PART NOTE:
// When an episode has partCount > 1:
//   - `duration` = TOTAL seconds across ALL parts (already summed by sync.js)
//   - `partCount` = number of Telegram file parts
//   - The audio_handler builds ?part=1 ... ?part=N URLs automatically
//   - UI just shows the episode title and combined duration — no part labels

class EpisodeModel {
  final String id;
  final String seriesId;
  final int    episodeNumber;
  final String title;
  final int?   duration;    // TOTAL combined duration in seconds
  final int    partCount;
  final bool   isMultiPart;
  final bool   isActive;

  const EpisodeModel({
    required this.id,
    required this.seriesId,
    required this.episodeNumber,
    required this.title,
    this.duration,
    this.partCount   = 1,
    this.isMultiPart = false,
    this.isActive    = true,
  });

  factory EpisodeModel.fromJson(Map<String, dynamic> json) {
    final partCount = json['partCount'] as int? ?? 1;
    return EpisodeModel(
      id:            json['id']?.toString() ?? '',
      seriesId:      json['seriesId']?.toString() ?? '',
      episodeNumber: json['episodeNumber'] as int? ?? 0,
      title:         json['title']?.toString() ?? '',
      duration:      json['duration'] as int?,  // combined total from DB
      partCount:     partCount,
      isMultiPart:   partCount > 1,
      isActive:      json['isActive'] as bool? ?? true,
    );
  }

  /// Formats the TOTAL combined duration.
  /// e.g. 793 seconds → "13:13"
  /// e.g. 3810 seconds → "01:03:30"
  String get formattedDuration {
    if (duration == null) return '--:--';
    final h = duration! ~/ 3600;
    final m = (duration! % 3600) ~/ 60;
    final s = duration! % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:'
             '${m.toString().padLeft(2, '0')}:'
             '${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}