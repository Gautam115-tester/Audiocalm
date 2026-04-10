// lib/features/downloads/data/services/download_manager.dart

import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/download_model.dart';
import '../services/encryption_service.dart';
import '../../../../core/constants/api_constants.dart';
import '../../../../core/constants/app_constants.dart';

class DownloadManager extends StateNotifier<Map<String, DownloadModel>> {
  final EncryptionService _encryptionService;
  final Dio _dio;
  final _uuid = const Uuid();

  DownloadManager(this._encryptionService)
      : _dio = Dio(BaseOptions(
          baseUrl: ApiConstants.baseUrl,
          receiveTimeout: const Duration(minutes: 10),
          connectTimeout: const Duration(seconds: 30),
        )),
        super({}) {
    _loadSavedDownloads();
  }

  void _loadSavedDownloads() {
    try {
      final box = Hive.box(AppConstants.downloadsBox);
      final downloads = <String, DownloadModel>{};
      for (final key in box.keys) {
        final item = box.get(key);
        if (item is DownloadModel) {
          downloads[item.mediaId] = item;
        }
      }
      state = downloads;
    } catch (_) {}
  }

  bool isDownloaded(String mediaId) {
    final item = state[mediaId];
    if (item == null) return false;
    return item.isCompleted && File(item.encryptedFilePath).existsSync();
  }

  bool isDownloading(String mediaId) {
    return state[mediaId]?.isInProgress ?? false;
  }

  DownloadModel? getDownload(String mediaId) => state[mediaId];

  Future<void> startDownload({
    required String mediaId,
    required String title,
    required String mediaType,
    required int partCount,
    String? artworkUrl,
    String? subtitle,
  }) async {
    if (isDownloaded(mediaId) || isDownloading(mediaId)) return;

    final id = _uuid.v4();
    final dir = await _getDownloadsDir();
    final encryptedPath = '${dir.path}/${mediaId}_enc.bin';

    final model = DownloadModel(
      id: id,
      mediaId: mediaId,
      title: title,
      artworkUrl: artworkUrl,
      mediaType: mediaType,
      encryptedFilePath: encryptedPath,
      totalParts: partCount,
      createdAt: DateTime.now(),
      subtitle: subtitle,
    );

    _updateState(model);
    _runDownload(model, mediaType, partCount);
  }

  Future<void> _runDownload(
      DownloadModel model, String mediaType, int partCount) async {
    try {
      final dir = await _getDownloadsDir();
      final List<String> partPaths = [];

      // ── Build stream URLs for each part ──────────────────────────────────
      // The backend /stream endpoint supports ?part=N for multi-part files.
      // The /download endpoint is a direct binary stream (no JSON wrapper).
      // We use /stream?part=N for downloading since it supports Range headers
      // and works for both single and multi-part content.
      final List<String> downloadUrls = [];

      if (partCount <= 1) {
        // Single part: use the download endpoint for the cleanest binary stream
        final endpoint = mediaType == 'episode'
            ? ApiConstants.episodeDownload(model.mediaId)
            : ApiConstants.songDownload(model.mediaId);
        downloadUrls.add('${ApiConstants.baseUrl}$endpoint');
      } else {
        // Multi-part: use ?part=N on the stream endpoint
        final streamEndpoint = mediaType == 'episode'
            ? ApiConstants.episodeStream(model.mediaId)
            : ApiConstants.songStream(model.mediaId);
        for (int i = 1; i <= partCount; i++) {
          downloadUrls
              .add('${ApiConstants.baseUrl}$streamEndpoint?part=$i');
        }
      }

      // ── Download each part directly as binary ─────────────────────────────
      for (int i = 0; i < downloadUrls.length; i++) {
        final partPath = '${dir.path}/${model.mediaId}_part$i.tmp';
        partPaths.add(partPath);

        await _dio.download(
          downloadUrls[i],
          partPath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final partProgress = received / total;
              final overallProgress =
                  (i + partProgress) / downloadUrls.length * 0.80;
              _updateProgress(model, 'downloading', overallProgress, i + 1);
            }
          },
          options: Options(
            // Force binary response — don't let Dio try to decode as JSON
            responseType: ResponseType.bytes,
            followRedirects: true,
            receiveTimeout: const Duration(minutes: 10),
          ),
        );

        model.downloadedParts = i + 1;
        _updateState(model);
      }

      // ── Merge if multiple parts ───────────────────────────────────────────
      String mergedPath;
      if (partPaths.length > 1) {
        _updateProgress(model, 'merging', 0.82, downloadUrls.length);
        mergedPath = '${dir.path}/${model.mediaId}_merged.tmp';
        await _mergeParts(partPaths, mergedPath);
      } else {
        mergedPath = partPaths.first;
      }

      // ── Encrypt ───────────────────────────────────────────────────────────
      _updateProgress(model, 'encrypting', 0.90, downloadUrls.length);
      await _encryptionService.encryptFile(
          mergedPath, model.encryptedFilePath);

      // ── Cleanup temp files ────────────────────────────────────────────────
      for (final path in partPaths) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      if (partPaths.length > 1) {
        try {
          await File(mergedPath).delete();
        } catch (_) {}
      }

      // ── Done ──────────────────────────────────────────────────────────────
      final encFile = File(model.encryptedFilePath);
      final size =
          await encFile.exists() ? await encFile.length() : 0;
      model.fileSizeBytes = size;
      model.status = 'completed';
      model.progress = 1.0;
      _updateState(model);
    } catch (e) {
      model.status = 'failed';
      model.errorMessage = e.toString();
      model.progress = 0.0;
      _updateState(model);
    }
  }

  Future<void> _mergeParts(List<String> partPaths, String outputPath) async {
    final outputFile = File(outputPath);
    final sink = outputFile.openWrite();

    for (final path in partPaths) {
      final file = File(path);
      if (await file.exists()) {
        await sink.addStream(file.openRead());
      }
    }

    await sink.flush();
    await sink.close();
  }

  void _updateProgress(
      DownloadModel model, String status, double progress, int parts) {
    model.status = status;
    model.progress = progress;
    model.downloadedParts = parts;
    _updateState(model);
  }

  void _updateState(DownloadModel model) {
    state = {...state, model.mediaId: model};
    try {
      final box = Hive.box(AppConstants.downloadsBox);
      box.put('dl_${model.mediaId}', model);
    } catch (_) {}
  }

  Future<String?> getDecryptedPath(String mediaId) async {
    final download = state[mediaId];
    if (download == null || !download.isCompleted) return null;

    try {
      return await _encryptionService
          .decryptToTemp(download.encryptedFilePath);
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteDownload(String mediaId) async {
    final download = state[mediaId];
    if (download == null) return;

    try {
      final file = File(download.encryptedFilePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}

    final newState = Map<String, DownloadModel>.from(state);
    newState.remove(mediaId);
    state = newState;

    try {
      final box = Hive.box(AppConstants.downloadsBox);
      box.delete('dl_$mediaId');
    } catch (_) {}
  }

  Future<void> clearAllDownloads() async {
    for (final mediaId in state.keys.toList()) {
      await deleteDownload(mediaId);
    }
    await _encryptionService.clearDecryptedCache();
  }

  Future<int> getTotalStorageBytes() async {
    int total = 0;
    for (final item in state.values) {
      if (item.isCompleted) {
        total += item.fileSizeBytes;
      }
    }
    return total;
  }

  String formatStorageSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  Future<Directory> _getDownloadsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir =
        Directory('${appDir.path}/${AppConstants.downloadsDir}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}

// Providers
final encryptionServiceProvider = Provider<EncryptionService>((ref) {
  return EncryptionService();
});

final downloadManagerProvider =
    StateNotifierProvider<DownloadManager, Map<String, DownloadModel>>(
        (ref) {
  final encService = ref.watch(encryptionServiceProvider);
  return DownloadManager(encService);
});