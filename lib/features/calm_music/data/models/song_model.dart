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
    return SongModel(
      id:          json['id']?.toString() ?? '',
      albumId:     json['album_id']?.toString() ?? '',   // ← changed
      trackNumber: json['track_number'] as int? ?? 0,    // ← changed
      title:       json['title']?.toString() ?? '',
      artist:      json['artist']?.toString(),
      duration:    json['duration_seconds'] as int?,     // ← changed
      isMultiPart: json['is_multi_part'] as bool? ?? false,
      isActive:    true,
      coverUrl:    json['cover_image_url']?.toString(),  // ← added
    );
  }

  String get formattedDuration {
    if (duration == null) return '--:--';
    final m = duration! ~/ 60;
    final s = duration! % 60;
    return '${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
  }
}