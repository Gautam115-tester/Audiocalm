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
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString(),
      coverUrl: json['coverUrl']?.toString(),
      isActive: json['isActive'] as bool? ?? true,
      trackCount:
          json['_count']?['songs'] as int? ?? json['trackCount'] as int? ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'coverUrl': coverUrl,
        'isActive': isActive,
        'trackCount': trackCount,
        'createdAt': createdAt.toIso8601String(),
      };
}
