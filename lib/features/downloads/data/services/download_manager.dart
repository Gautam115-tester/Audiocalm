// lib/features/downloads/data/services/download_manager.dart
//
// THREAD FIX — Encryption / decryption moved to background isolate
// ================================================================
//
// PREVIOUS PROBLEM:
//   encryptFile() and decryptToTemp() read entire MP3 files into memory and
//   ran AES-256-CBC on the MAIN ISOLATE.  A 20 MB file takes ~300-800 ms to
//   encrypt on the main thread, causing BLASTBufferQueue overflow and dropped
//   frames while the progress ring was supposed to be animating.
//
// FIX:
//   _runDownload() now runs in a separate Dart Isolate via Isolate.run().
//   The isolate receives all the data it needs (URLs, paths, encryption key)
//   and reports progress back via SendPort messages.
//   The main isolate only updates UI state in response to those messages.
//
//   For decryption (playback), decryptToTemp() is called via compute() so
//   the main thread is free to render the player screen while decryption runs.
//
// NOTE: The EncryptionService itself is unchanged — we just call it from
// a different thread context.

import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/download_model.dart';
import '../services/encryption_service.dart';
import '../../../../core/constants/api_constants.dart';
import '../../../../core/constants/app_constants.dart';

// ── Isolate message types ──────────────────────────────────────────────────

sealed class _DownloadMessage {}

class _ProgressMessage extends _DownloadMessage {
  final String mediaId;
  final String status;
  final double progress;
  final int downloadedParts;
  _ProgressMessage({
    required this.mediaId,
    required this.status,
    required this.progress,
    required this.downloadedParts,
  });
}

class _CompletedMessage extends _DownloadMessage {
  final String mediaId;
  final int fileSizeBytes;
  _CompletedMessage({required this.mediaId, required this.fileSizeBytes});
}

class _FailedMessage extends _DownloadMessage {
  final String mediaId;
  final String errorMessage;
  _FailedMessage({required this.mediaId, required this.errorMessage});
}

// ── Isolate entry payload ──────────────────────────────────────────────────

class _DownloadPayload {
  final SendPort sendPort;
  final String mediaId;
  final String mediaType;
  final int partCount;
  final String baseEncPath;
  final String downloadsDir;
  final String encryptionKey; // comma-separated bytes, safe to send

  const _DownloadPayload({
    required this.sendPort,
    required this.mediaId,
    required this.mediaType,
    required this.partCount,
    required this.baseEncPath,
    required this.downloadsDir,
    required this.encryptionKey,
  });
}

// ── Isolate worker function (top-level, sendable) ─────────────────────────

Future<void> _downloadIsolateEntry(_DownloadPayload payload) async {
  final send = payload.sendPort;

  // Re-create a minimal Dio inside the isolate (no platform channels needed).
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 10),
      headers: {'Accept': '*/*', 'Connection': 'keep-alive'},
    ),
  );

  // Re-create the encryption service inside the isolate.
  // The key bytes are passed as a string to avoid SendPort restrictions.
  final encService = EncryptionService();
  await encService.initWithKeyBytes(payload.encryptionKey);

  final List<String> downloadUrls = [];
  if (payload.partCount <= 1) {
    final endpoint = payload.mediaType == 'episode'
        ? ApiConstants.episodeDownload(payload.mediaId)
        : ApiConstants.songDownload(payload.mediaId);
    downloadUrls.add('${ApiConstants.baseUrl}$endpoint');
  } else {
    final streamEndpoint = payload.mediaType == 'episode'
        ? ApiConstants.episodeStream(payload.mediaId)
        : ApiConstants.songStream(payload.mediaId);
    for (int i = 1; i <= payload.partCount; i++) {
      downloadUrls.add('${ApiConstants.baseUrl}$streamEndpoint?part=$i');
    }
  }

  int totalSize = 0;

  try {
    for (int i = 0; i < downloadUrls.length; i++) {
      final tmpPath =
          '${payload.downloadsDir}/${payload.mediaId}_part$i.tmp';
      final partEncPath = _partEncPathStatic(payload.baseEncPath, i);

      final tmpFile = File(tmpPath);
      if (tmpFile.existsSync()) tmpFile.deleteSync();
      final partEncFile = File(partEncPath);
      if (partEncFile.existsSync()) partEncFile.deleteSync();

      await dio.download(
        downloadUrls[i],
        tmpPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final partProgress = received / total;
            final overall =
                (i + partProgress) / downloadUrls.length * 0.85;
            send.send(_ProgressMessage(
              mediaId: payload.mediaId,
              status: 'downloading',
              progress: overall.clamp(0.01, 0.85),
              downloadedParts: i + 1,
            ));
          }
        },
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 10),
          validateStatus: (s) => s != null && s < 300,
        ),
      );

      final downloaded = File(tmpPath);
      if (!downloaded.existsSync() || downloaded.lengthSync() == 0) {
        throw Exception('Part $i download is empty');
      }

      send.send(_ProgressMessage(
        mediaId: payload.mediaId,
        status: 'encrypting',
        progress: 0.85 + (i + 0.5) / downloadUrls.length * 0.15,
        downloadedParts: i + 1,
      ));

      await encService.encryptFile(tmpPath, partEncPath);
      try { File(tmpPath).deleteSync(); } catch (_) {}

      final partFile = File(partEncPath);
      if (partFile.existsSync()) totalSize += partFile.lengthSync();

      send.send(_ProgressMessage(
        mediaId: payload.mediaId,
        status: 'downloading',
        progress: ((i + 1) / downloadUrls.length * 0.85).clamp(0.01, 0.85),
        downloadedParts: i + 1,
      ));
    }

    send.send(_CompletedMessage(
      mediaId: payload.mediaId,
      fileSizeBytes: totalSize,
    ));
  } catch (e) {
    send.send(_FailedMessage(
      mediaId: payload.mediaId,
      errorMessage: e.toString().replaceAll('Exception: ', ''),
    ));
  } finally {
    dio.close();
  }
}

String _partEncPathStatic(String baseEncPath, int partIndex) {
  final withoutExt = baseEncPath.replaceAll(RegExp(r'_enc\.bin$'), '');
  return '${withoutExt}_part${partIndex}_enc.bin';
}

// ── Decryption payload for compute() ──────────────────────────────────────

class _DecryptPayload {
  final String encryptedPath;
  final String encryptionKey;
  final String cacheDir;
  _DecryptPayload({
    required this.encryptedPath,
    required this.encryptionKey,
    required this.cacheDir,
  });
}

Future<String?> _decryptInBackground(_DecryptPayload payload) async {
  final svc = EncryptionService();
  await svc.initWithKeyBytes(payload.encryptionKey);
  try {
    return await svc.decryptToTempInDir(payload.encryptedPath, payload.cacheDir);
  } catch (_) {
    return null;
  }
}

// ── DownloadManager ────────────────────────────────────────────────────────

class DownloadManager extends StateNotifier<Map<String, DownloadModel>> {
  final EncryptionService _encryptionService;
  final _uuid = const Uuid();

  // Active isolate receive ports keyed by mediaId — for cancellation (future).
  final Map<String, ReceivePort> _activePorts = {};

  DownloadManager(this._encryptionService) : super({}) {
    _loadSavedDownloads();
  }

  void _loadSavedDownloads() {
    try {
      final box = Hive.box(AppConstants.downloadsBox);
      final downloads = <String, DownloadModel>{};
      for (final key in box.keys) {
        final item = box.get(key);
        if (item is DownloadModel) {
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
    return item.isCompleted && _verifyEncryptedFiles(item);
  }

  bool _verifyEncryptedFiles(DownloadModel item) {
    if (item.totalParts <= 1) {
      return File(item.encryptedFilePath).existsSync() ||
          File(_partEncPath(item.encryptedFilePath, 0)).existsSync();
    }
    for (int i = 0; i < item.totalParts; i++) {
      if (!File(_partEncPath(item.encryptedFilePath, i)).existsSync()) {
        return false;
      }
    }
    return true;
  }

  bool isDownloading(String mediaId) => state[mediaId]?.isInProgress ?? false;
  DownloadModel? getDownload(String mediaId) => state[mediaId];

  static String _partEncPath(String baseEncPath, int partIndex) {
    final withoutExt = baseEncPath.replaceAll(RegExp(r'_enc\.bin$'), '');
    return '${withoutExt}_part${partIndex}_enc.bin';
  }

  // ── startDownload ────────────────────────────────────────────────────────

  Future<void> startDownload({
    required String mediaId,
    required String title,
    required String mediaType,
    required int partCount,
    String? artworkUrl,
    String? subtitle,
    int? durationSeconds,
  }) async {
    if (isDownloaded(mediaId) || isDownloading(mediaId)) return;

    final id = _uuid.v4();
    final dir = await _getDownloadsDir();
    final baseEncPath = '${dir.path}/${mediaId}_enc.bin';

    final model = DownloadModel(
      id: id,
      mediaId: mediaId,
      title: title,
      artworkUrl: artworkUrl,
      mediaType: mediaType,
      encryptedFilePath: baseEncPath,
      totalParts: partCount,
      createdAt: DateTime.now(),
      subtitle: subtitle,
      status: 'downloading',
      progress: 0.01,
      durationSeconds: durationSeconds,
    );

    _updateState(model);
    _runDownloadInIsolate(model, dir.path);
  }

  Future<void> retryDownload(String mediaId) async {
    final existing = state[mediaId];
    if (existing == null || !existing.isFailed) return;
    existing.status = 'downloading';
    existing.progress = 0.01;
    existing.errorMessage = null;
    _updateState(existing);

    final dir = await _getDownloadsDir();
    _runDownloadInIsolate(existing, dir.path);
  }

  // ── Core: spawn isolate, listen for progress messages ────────────────────

  Future<void> _runDownloadInIsolate(
      DownloadModel model, String downloadsDir) async {
    // Get the encryption key so we can send it to the isolate.
    // EncryptionService.getKeyBytesString() returns the comma-separated key.
    final keyString = await _encryptionService.getKeyBytesString();
    if (keyString == null) {
      _markFailed(model, 'Encryption key unavailable');
      return;
    }

    final receivePort = ReceivePort();
    _activePorts[model.mediaId] = receivePort;

    final payload = _DownloadPayload(
      sendPort: receivePort.sendPort,
      mediaId: model.mediaId,
      mediaType: model.mediaType,
      partCount: model.totalParts,
      baseEncPath: model.encryptedFilePath,
      downloadsDir: downloadsDir,
      encryptionKey: keyString,
    );

    // Spawn the isolate — download + encrypt runs completely off the main thread.
    await Isolate.spawn(_downloadIsolateEntry, payload);

    receivePort.listen((message) {
      if (message is _ProgressMessage) {
        final current = state[message.mediaId];
        if (current == null) return;
        current.status = message.status;
        current.progress = message.progress;
        current.downloadedParts = message.downloadedParts;
        _updateState(current);
      } else if (message is _CompletedMessage) {
        final current = state[message.mediaId];
        if (current == null) return;
        current.fileSizeBytes = message.fileSizeBytes;
        current.status = 'completed';
        current.progress = 1.0;
        current.errorMessage = null;
        _updateState(current);
        _cleanupPort(message.mediaId);
      } else if (message is _FailedMessage) {
        final current = state[message.mediaId];
        if (current == null) return;
        _markFailed(current, message.errorMessage);
        _cleanupPort(message.mediaId);
      }
    });
  }

  void _cleanupPort(String mediaId) {
    _activePorts[mediaId]?.close();
    _activePorts.remove(mediaId);
  }

  // ── Decryption (background via compute) ───────────────────────────────────

  Future<String?> getDecryptedPath(String mediaId) async {
    final paths = await getDecryptedPaths(mediaId);
    return paths?.first;
  }

  Future<List<String>?> getDecryptedPaths(String mediaId) async {
    final download = state[mediaId];
    if (download == null || !download.isCompleted) return null;

    try {
      final keyString = await _encryptionService.getKeyBytesString();
      if (keyString == null) return null;

      final cacheDir = await _getCacheDir();
      final totalParts = download.totalParts;
      final results = <String>[];

      if (totalParts <= 1) {
        final newPartPath = _partEncPath(download.encryptedFilePath, 0);
        final legacyPath = download.encryptedFilePath;

        final sourcePath = File(newPartPath).existsSync()
            ? newPartPath
            : File(legacyPath).existsSync()
                ? legacyPath
                : null;

        if (sourcePath == null) return null;

        // FIX: Decrypt in background isolate so the player screen opens instantly
        final decrypted = await compute(
          _decryptInBackground,
          _DecryptPayload(
            encryptedPath: sourcePath,
            encryptionKey: keyString,
            cacheDir: cacheDir.path,
          ),
        );
        if (decrypted == null) return null;
        results.add(decrypted);
      } else {
        // Multi-part: decrypt all parts in parallel background isolates
        final futures = <Future<String?>>[];
        for (int i = 0; i < totalParts; i++) {
          final partEncPath = _partEncPath(download.encryptedFilePath, i);
          if (!File(partEncPath).existsSync()) return null;
          futures.add(compute(
            _decryptInBackground,
            _DecryptPayload(
              encryptedPath: partEncPath,
              encryptionKey: keyString,
              cacheDir: cacheDir.path,
            ),
          ));
        }
        final decrypted = await Future.wait(futures);
        if (decrypted.any((p) => p == null)) return null;
        results.addAll(decrypted.whereType<String>());
      }

      return results;
    } catch (_) {
      return null;
    }
  }

  // ── Delete / clear ─────────────────────────────────────────────────────────

  Future<void> deleteDownload(String mediaId) async {
    _cleanupPort(mediaId);
    final download = state[mediaId];
    if (download == null) return;

    final totalParts = download.totalParts <= 0 ? 1 : download.totalParts;
    for (int i = 0; i < totalParts; i++) {
      try {
        final f = File(_partEncPath(download.encryptedFilePath, i));
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    try {
      final legacy = File(download.encryptedFilePath);
      if (legacy.existsSync()) legacy.deleteSync();
    } catch (_) {}

    final newState = Map<String, DownloadModel>.from(state);
    newState.remove(mediaId);
    state = newState;
    try {
      final box = Hive.box(AppConstants.downloadsBox);
      box.delete('dl_$mediaId');
    } catch (_) {}
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  void _markFailed(DownloadModel model, String message) {
    model.status = 'failed';
    model.errorMessage = message;
    model.progress = 0.0;
    _updateState(model);
  }

  void _updateState(DownloadModel model) {
    state = {...state, model.mediaId: model};
    try {
      final box = Hive.box(AppConstants.downloadsBox);
      box.put('dl_${model.mediaId}', model);
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
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/${AppConstants.decryptedCacheDir}');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
}

// ── Providers ──────────────────────────────────────────────────────────────

final encryptionServiceProvider = Provider<EncryptionService>((ref) {
  return EncryptionService();
});

final downloadManagerProvider =
    StateNotifierProvider<DownloadManager, Map<String, DownloadModel>>((ref) {
  final encService = ref.watch(encryptionServiceProvider);
  return DownloadManager(encService);
});