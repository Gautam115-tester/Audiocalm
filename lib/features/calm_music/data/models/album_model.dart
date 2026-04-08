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
      coverUrl:   json['cover_image_url']?.toString(),  // ← changed
      isActive:   json['is_active'] as bool? ?? true,
      trackCount: json['track_count'] as int? ?? 0,     // ← changed
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}