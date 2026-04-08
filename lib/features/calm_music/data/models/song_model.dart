// lib/features/calm_music/data/models/song_model.dart

class SongModel {
  final String id;
  final String albumId;
  final int trackNumber;
  final String title;
  final String? telegramFileId;
  final int? duration; // seconds
  final int partCount;
  final bool isActive;

  const SongModel({
    required this.id,
    required this.albumId,
    required this.trackNumber,
    required this.title,
    this.telegramFileId,
    this.duration,
    this.partCount = 1,
    this.isActive = true,
  });

  factory SongModel.fromJson(Map<String, dynamic> json) {
    return SongModel(
      id: json['id']?.toString() ?? '',
      albumId: json['albumId']?.toString() ?? '',
      trackNumber: json['trackNumber'] as int? ?? 0,
      title: json['title']?.toString() ?? '',
      telegramFileId: json['telegramFileId']?.toString(),
      duration: json['duration'] as int?,
      partCount: json['partCount'] as int? ?? 1,
      isActive: json['isActive'] as bool? ?? true,
    );
  }

  String get formattedDuration {
    if (duration == null) return '--:--';
    final m = duration! ~/ 60;
    final s = duration! % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'albumId': albumId,
        'trackNumber': trackNumber,
        'title': title,
        'telegramFileId': telegramFileId,
        'duration': duration,
        'partCount': partCount,
        'isActive': isActive,
      };
}
