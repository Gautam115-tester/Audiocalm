class SeriesModel {
  final String id;
  final String title;
  final String? description;
  final String? coverUrl;
  final bool isActive;
  final int episodeCount;
  final DateTime createdAt;

  const SeriesModel({
    required this.id,
    required this.title,
    this.description,
    this.coverUrl,
    required this.isActive,
    this.episodeCount = 0,
    required this.createdAt,
  });

  factory SeriesModel.fromJson(Map<String, dynamic> json) {
    return SeriesModel(
      id:           json['id']?.toString() ?? '',
      title:        json['title']?.toString() ?? '',
      description:  json['description']?.toString(),
      coverUrl:     json['cover_image_url']?.toString(),   // ← changed
      isActive:     json['is_active'] as bool? ?? true,
      episodeCount: json['episode_count'] as int? ?? 0,    // ← changed
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}