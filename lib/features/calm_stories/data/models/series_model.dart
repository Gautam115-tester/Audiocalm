// lib/features/calm_stories/data/models/series_model.dart

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
      coverUrl:     json['coverUrl']?.toString(),          // backend sends 'coverUrl'
      isActive:     json['isActive'] as bool? ?? true,     // backend sends 'isActive'
      episodeCount: json['episodeCount'] as int? ?? 0,     // backend sends 'episodeCount'
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}