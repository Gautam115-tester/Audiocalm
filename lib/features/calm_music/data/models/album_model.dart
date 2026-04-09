// lib/features/calm_music/data/models/album_model.dart

class AlbumModel {
  final String id;
  final String title;
  final String? artist;
  final String? coverUrl;
  final bool isActive;
  final int trackCount;
  final DateTime createdAt;

  const AlbumModel({
    required this.id,
    required this.title,
    this.artist,
    this.coverUrl,
    required this.isActive,
    this.trackCount = 0,
    required this.createdAt,
  });

  factory AlbumModel.fromJson(Map<String, dynamic> json) {
    return AlbumModel(
      id:         json['id']?.toString() ?? '',
      title:      json['title']?.toString() ?? '',
      artist:     json['artist']?.toString(),
      coverUrl:   json['coverUrl']?.toString(),       // backend sends 'coverUrl'
      isActive:   json['isActive'] as bool? ?? true,  // backend sends 'isActive'
      trackCount: json['trackCount'] as int? ?? 0,    // backend sends 'trackCount'
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}