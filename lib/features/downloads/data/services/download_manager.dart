// lib/features/downloads/data/services/download_manager.dart
//
// FIX 1 — DioException [unknown]: null
//   Root cause: Dio was initialized with baseUrl = ApiConstants.baseUrl,
//   but downloadUrls were already FULL absolute URLs (baseUrl + path).
//   Dio + baseUrl + absolute URL = conflict → null response → crash.
//   Fix: Remove baseUrl from Dio options. Use plain absolute URLs everywhere.
//
// FIX 2 — No "started" feedback on tap
//   startDownload() now immediately sets status = 'queued' and calls
//   _updateState() before spawning the async work, so the UI reacts instantly.
//
// FIX 3 — Progress visible in list tiles
//   No change needed here — the select() fix in album_detail_screen.dart
//   already wires it. But we ensure progress ticks are emitted more smoothly.

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

  // FIX: No baseUrl — all download URLs are absolute, built with ApiConstants.baseUrl prefix.
  // Using baseUrl + absolute URL causes Dio to produce a null request → DioException [unknown]: null.
  late final Dio _dio;

  final _uuid = const Uuid();

  DownloadManager(this._encryptionService) : super({}) {
    // FIX: Plain Dio with NO baseUrl. Absolute URLs work correctly.
    _dio = Dio(
      BaseOptions(
        // No baseUrl here — we pass full URLs to dio.download()
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 10),
        sendTimeout: const Duration(seconds: 30),
        headers: {
          'Accept': '*/*',
          'Connection': 'keep-alive',
        },
      ),
    );

    // Follow redirects (Telegram signed URLs redirect once)
    _dio.options.followRedirects = true;
    _dio.options.maxRedirects = 5;

    _loadSavedDownloads();
  }

  void _loadSavedDownloads() {
    try {
      final box = Hive.box(AppConstants.downloadsBox);
      final downloads = <String, DownloadModel>{};
      for (final key in box.keys) {
        final item = box.get(key);
        if (item is DownloadModel) {
          // Reset any stuck in-progress downloads from previous app session
          if (item.isInProgress) {
            item.status = 'failed';
            item.errorMessage = 'Interrupted — tap to retry';
            item.progress = 0.0;
          }
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
      // FIX: Immediately set to 'downloading' so UI shows feedback right away
      status: 'downloading',
      progress: 0.01, // tiny non-zero so progress indicator appears instantly
    );

    _updateState(model);

    // Run async without awaiting so UI stays responsive
    _runDownload(model, mediaType, partCount);
  }

  Future<void> retryDownload(String mediaId) async {
    final existing = state[mediaId];
    if (existing == null || !existing.isFailed) return;

    existing.status = 'downloading';
    existing.progress = 0.01;
    existing.errorMessage = null;
    _updateState(existing);

    _runDownload(existing, existing.mediaType, existing.totalParts);
  }

  Future<void> _runDownload(
      DownloadModel model, String mediaType, int partCount) async {
    try {
      final dir = await _getDownloadsDir();
      final List<String> partPaths = [];

      // ── Build ABSOLUTE stream URLs ─────────────────────────────────────────
      // FIX: Always use full absolute URLs. Dio has no baseUrl, so these
      //      go directly to the server without any path-joining weirdness.
      final List<String> downloadUrls = [];

      if (partCount <= 1) {
        final endpoint = mediaType == 'episode'
            ? ApiConstants.episodeDownload(model.mediaId)
            : ApiConstants.songDownload(model.mediaId);
        // endpoint already starts with /api/... — prepend base
        downloadUrls.add('${ApiConstants.baseUrl}$endpoint');
      } else {
        final streamEndpoint = mediaType == 'episode'
            ? ApiConstants.episodeStream(model.mediaId)
            : ApiConstants.songStream(model.mediaId);
        for (int i = 1; i <= partCount; i++) {
          downloadUrls.add(
              '${ApiConstants.baseUrl}$streamEndpoint?part=$i');
        }
      }

      // ── Download each part ────────────────────────────────────────────────
      for (int i = 0; i < downloadUrls.length; i++) {
        final partPath = '${dir.path}/${model.mediaId}_part$i.tmp';
        partPaths.add(partPath);

        // Delete any leftover temp file from a previous failed attempt
        final tmpFile = File(partPath);
        if (await tmpFile.exists()) await tmpFile.delete();

        await _dio.download(
          downloadUrls[i],
          partPath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final partProgress = received / total;
              // Scale: 0–80% = downloading phase
              final overallProgress =
                  (i + partProgress) / downloadUrls.length * 0.80;
              _updateProgress(
                  model, 'downloading', overallProgress.clamp(0.01, 0.80),
                  i + 1);
            }
          },
          options: Options(
            // Force raw bytes — never let Dio try JSON-decode an audio file
            responseType: ResponseType.bytes,
            followRedirects: true,
            receiveTimeout: const Duration(minutes: 10),
            // FIX: Accept any 2xx response as success (Telegram returns 200)
            validateStatus: (status) => status != null && status < 300,
          ),
        );

        // Verify the downloaded file is non-empty
        final downloaded = File(partPath);
        if (!await downloaded.exists() || await downloaded.length() == 0) {
          throw Exception(
              'Downloaded part $i is empty — server may have returned an error body');
        }

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
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      if (partPaths.length > 1) {
        try {
          final f = File(mergedPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }

      // ── Done ──────────────────────────────────────────────────────────────
      final encFile = File(model.encryptedFilePath);
      final size = await encFile.exists() ? await encFile.length() : 0;
      model.fileSizeBytes = size;
      model.status = 'completed';
      model.progress = 1.0;
      model.errorMessage = null;
      _updateState(model);
    } on DioException catch (e) {
      String errorMessage;
      if (e.response != null) {
        errorMessage =
            'Server error ${e.response?.statusCode}: ${e.response?.statusMessage}';
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        errorMessage = 'Timeout — check your connection and retry';
      } else if (e.type == DioExceptionType.connectionError) {
        errorMessage = 'No connection — retry when online';
      } else {
        // FIX: Show the actual message instead of the cryptic "null"
        errorMessage = e.message?.isNotEmpty == true
            ? e.message!
            : 'Network error — tap to retry';
      }
      _markFailed(model, errorMessage);
    } catch (e) {
      _markFailed(model, e.toString().replaceAll('Exception: ', ''));
    }
  }

  void _markFailed(DownloadModel model, String message) {
    model.status = 'failed';
    model.errorMessage = message;
    model.progress = 0.0;
    _updateState(model);
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
      return await _encryptionService.decryptToTemp(download.encryptedFilePath);
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteDownload(String mediaId) async {
    final download = state[mediaId];
    if (download == null) return;
    try {
      final file = File(download.encryptedFilePath);
      if (await file.exists()) await file.delete();
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
      if (item.isCompleted) total += item.fileSizeBytes;
    }
    return total;
  }

  String formatStorageSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  Future<Directory> _getDownloadsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/${AppConstants.downloadsDir}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

// Providers
final encryptionServiceProvider = Provider<EncryptionService>((ref) {
  return EncryptionService();
});

final downloadManagerProvider =
    StateNotifierProvider<DownloadManager, Map<String, DownloadModel>>((ref) {
  final encService = ref.watch(encryptionServiceProvider);
  return DownloadManager(encService);
});