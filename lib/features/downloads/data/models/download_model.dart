// lib/features/downloads/data/models/download_model.dart

import 'package:hive/hive.dart';

part 'download_model.g.dart';

enum DownloadStatus { pending, downloading, merging, encrypting, completed, failed }

@HiveType(typeId: 0)
class DownloadModel extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String mediaId;

  @HiveField(2)
  final String title;

  @HiveField(3)
  final String? artworkUrl;

  @HiveField(4)
  final String mediaType; // 'episode' | 'song'

  @HiveField(5)
  final String encryptedFilePath;

  @HiveField(6)
  final int totalParts;

  @HiveField(7)
  late int downloadedParts;

  @HiveField(8)
  late String status;

  @HiveField(9)
  late double progress;

  @HiveField(10)
  final DateTime createdAt;

  @HiveField(11)
  late String? errorMessage;

  @HiveField(12)
  final String? subtitle;

  @HiveField(13)
  late int fileSizeBytes;

  DownloadModel({
    required this.id,
    required this.mediaId,
    required this.title,
    this.artworkUrl,
    required this.mediaType,
    required this.encryptedFilePath,
    this.totalParts = 1,
    this.downloadedParts = 0,
    this.status = 'pending',
    this.progress = 0.0,
    required this.createdAt,
    this.errorMessage,
    this.subtitle,
    this.fileSizeBytes = 0,
  });

  DownloadStatus get downloadStatus {
    return switch (status) {
      'pending' => DownloadStatus.pending,
      'downloading' => DownloadStatus.downloading,
      'merging' => DownloadStatus.merging,
      'encrypting' => DownloadStatus.encrypting,
      'completed' => DownloadStatus.completed,
      'failed' => DownloadStatus.failed,
      _ => DownloadStatus.pending,
    };
  }

  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isInProgress =>
      status == 'downloading' || status == 'merging' || status == 'encrypting';

  String get formattedSize {
    if (fileSizeBytes <= 0) return '--';
    if (fileSizeBytes < 1024) return '${fileSizeBytes}B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)}KB';
    }
    if (fileSizeBytes < 1024 * 1024 * 1024) {
      return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(fileSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }
}
