// lib/features/player/domain/media_item_model.dart

enum MediaType { episode, song }

class PlayableItem {
  final String id;
  final String title;
  final String? subtitle; // series/album name
  final String? artworkUrl;
  final int? duration; // seconds
  final int partCount;
  final MediaType type;
  final String streamUrl;
  final Map<String, dynamic> extras;

  const PlayableItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.artworkUrl,
    this.duration,
    this.partCount = 1,
    required this.type,
    required this.streamUrl,
    this.extras = const {},
  });

  bool get isEpisode => type == MediaType.episode;
  bool get isSong => type == MediaType.song;

  Duration? get durationDuration =>
      duration != null ? Duration(seconds: duration!) : null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'artworkUrl': artworkUrl,
        'duration': duration,
        'partCount': partCount,
        'type': type.name,
        'streamUrl': streamUrl,
        'extras': extras,
      };

  factory PlayableItem.fromJson(Map<String, dynamic> json) {
    return PlayableItem(
      id: json['id'] as String,
      title: json['title'] as String,
      subtitle: json['subtitle'] as String?,
      artworkUrl: json['artworkUrl'] as String?,
      duration: json['duration'] as int?,
      partCount: json['partCount'] as int? ?? 1,
      type: MediaType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => MediaType.song,
      ),
      streamUrl: json['streamUrl'] as String,
      extras: (json['extras'] as Map<String, dynamic>?) ?? {},
    );
  }

  PlayableItem copyWith({
    String? id,
    String? title,
    String? subtitle,
    String? artworkUrl,
    int? duration,
    int? partCount,
    MediaType? type,
    String? streamUrl,
    Map<String, dynamic>? extras,
  }) {
    return PlayableItem(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      duration: duration ?? this.duration,
      partCount: partCount ?? this.partCount,
      type: type ?? this.type,
      streamUrl: streamUrl ?? this.streamUrl,
      extras: extras ?? this.extras,
    );
  }
}
