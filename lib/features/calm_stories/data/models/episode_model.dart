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
    return EpisodeModel(
      id:            json['id']?.toString() ?? '',
      seriesId:      json['series_id']?.toString() ?? '',   // ← changed
      episodeNumber: json['episode_number'] as int? ?? 0,   // ← changed
      title:         json['title']?.toString() ?? '',
      duration:      json['duration_seconds'] as int?,      // ← changed
      isMultiPart:   json['is_multi_part'] as bool? ?? false,
      isActive:      true,
    );
  }

  // partCount is determined by calling /parts endpoint
  // For display purposes, use isMultiPart flag
  String get formattedDuration {
    if (duration == null) return '--:--';
    final h = duration! ~/ 3600;
    final m = (duration! % 3600) ~/ 60;
    final s = duration! % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2,'0')}:${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
    }
    return '${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
  }
}