// lib/features/calm_stories/data/models/episode_model.dart

class EpisodeModel {
  final String id;
  final String seriesId;
  final int episodeNumber;
  final String title;
  final int? duration;
  final int partCount;
  final bool isMultiPart;
  final bool isActive;

  const EpisodeModel({
    required this.id,
    required this.seriesId,
    required this.episodeNumber,
    required this.title,
    this.duration,
    this.partCount = 1,
    this.isMultiPart = false,
    this.isActive = true,
  });

  factory EpisodeModel.fromJson(Map<String, dynamic> json) {
    final partCount = json['partCount'] as int? ?? 1;
    return EpisodeModel(
      id:            json['id']?.toString() ?? '',
      seriesId:      json['seriesId']?.toString() ?? '',      // backend sends 'seriesId'
      episodeNumber: json['episodeNumber'] as int? ?? 0,      // backend sends 'episodeNumber'
      title:         json['title']?.toString() ?? '',
      duration:      json['duration'] as int?,                // backend sends 'duration'
      partCount:     partCount,
      isMultiPart:   partCount > 1,
      isActive:      json['isActive'] as bool? ?? true,
    );
  }

  String get formattedDuration {
    if (duration == null) return '--:--';
    final h = duration! ~/ 3600;
    final m = (duration! % 3600) ~/ 60;
    final s = duration! % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}