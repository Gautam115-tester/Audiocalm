// lib/features/calm_music/data/models/song_model.dart

class SongModel {
  final String id;
  final String albumId;
  final int trackNumber;
  final String title;
  final String? artist;
  final int? duration;
  final bool isMultiPart;
  final bool isActive;
  final String? coverUrl;

  const SongModel({
    required this.id,
    required this.albumId,
    required this.trackNumber,
    required this.title,
    this.artist,
    this.duration,
    this.isMultiPart = false,
    this.isActive = true,
    this.coverUrl,
  });

  factory SongModel.fromJson(Map<String, dynamic> json) {
    final partCount = json['partCount'] as int? ?? 1;
    return SongModel(
      id:          json['id']?.toString() ?? '',
      albumId:     json['albumId']?.toString() ?? '',     // backend sends 'albumId'
      trackNumber: json['trackNumber'] as int? ?? 0,      // backend sends 'trackNumber'
      title:       json['title']?.toString() ?? '',
      artist:      json['artist']?.toString(),
      duration:    json['duration'] as int?,              // backend sends 'duration'
      isMultiPart: partCount > 1,
      isActive:    json['isActive'] as bool? ?? true,
      coverUrl:    null, // songs don't have individual covers; use album cover
    );
  }

  String get formattedDuration {
    if (duration == null) return '--:--';
    final m = duration! ~/ 60;
    final s = duration! % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}