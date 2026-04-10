// lib/features/downloads/data/services/download_manager.dart
//
// ROOT CAUSE FIX — Multi-part MP3 offline playback only played part 1
// ===================================================================
//
// THE BUG (from logcat):
//   I/Mp3Extractor: Data size mismatch between stream (31747419) and
//                   Xing frame (17863717), using Xing value.
//
// MP3 files embed a Xing/VBRI VBR header in the very first frame that
// declares the total byte-count and total frame-count of that file.
// The old code did a raw byte-concat of part1.tmp + part2.tmp into a single
// merged file, then encrypted it.  When ExoPlayer opened the merged file,
// it read part1's Xing header which said "this file is 17 MB" — so it
// stopped decoding at 17 MB even though the file was 31 MB.  Result: only
// part 1 played, part 2 was silently skipped.
//
// THE FIX
// -------
// Store each downloaded part as its OWN encrypted file on disk:
//   <mediaId>_part0_enc.bin   ← encrypted part 1
//   <mediaId>_part1_enc.bin   ← encrypted part 2
//   …
// At playback time, decrypt each part file separately → N local URIs.
// Pass those URIs to the AudioHandler via PlayableItem.extras['offlinePartUrls']
// so the handler can play them sequentially with its existing multi-part logic.
//
// For single-part content the behaviour is identical to before.
//
// MIGRATION: old single-file downloads (<mediaId>_enc.bin) still work — the
// getDecryptedPath() fast-path returns the single file when the old layout
// is detected.

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

  late final Dio _dio;
  final _uuid = const Uuid();

  DownloadManager(this._encryptionService) : super({}) {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 10),
        sendTimeout: const Duration(seconds: 30),
        headers: {
          'Accept': '*/*',
          'Connection': 'keep-alive',
        },
      ),
    );
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

  /// Verify that all expected encrypted part files actually exist on disk.
  bool _verifyEncryptedFiles(DownloadModel item) {
    if (item.totalParts <= 1) {
      // Single part — old layout (<mediaId>_enc.bin) OR new layout (<mediaId>_part0_enc.bin)
      return File(item.encryptedFilePath).existsSync() ||
          File(_partEncPath(item.encryptedFilePath, 0)).existsSync();
    }
    // Multi-part — all part files must exist
    for (int i = 0; i < item.totalParts; i++) {
      if (!File(_partEncPath(item.encryptedFilePath, i)).existsSync()) {
        return false;
      }
    }
    return true;
  }

  bool isDownloading(String mediaId) => state[mediaId]?.isInProgress ?? false;
  DownloadModel? getDownload(String mediaId) => state[mediaId];

  // ── Part-file path helpers ────────────────────────────────────────────────

  /// Returns the encrypted file path for part [partIndex] (0-based).
  /// Replaces the trailing extension with _part{N}_enc.bin so each part
  /// gets its own file and is distinguishable from the legacy single-file path.
  static String _partEncPath(String baseEncPath, int partIndex) {
    // Strip the trailing extension from the base path, then add part suffix.
    // baseEncPath is typically: .../downloads/<uuid>_enc.bin
    final withoutExt = baseEncPath.replaceAll(RegExp(r'_enc\.bin$'), '');
    return '${withoutExt}_part${partIndex}_enc.bin';
  }

  // ── startDownload ─────────────────────────────────────────────────────────

  Future<void> startDownload({
    required String mediaId,
    required String title,
    required String mediaType,
    required int partCount,
    String? artworkUrl,
    String? subtitle,
    // FIX: Store total combined duration so offline playback knows the full
    // length from the start, preventing position > duration on the seekbar.
    int? durationSeconds,
  }) async {
    if (isDownloaded(mediaId) || isDownloading(mediaId)) return;

    final id = _uuid.v4();
    final dir = await _getDownloadsDir();
    // encryptedFilePath is the BASE path; per-part paths are derived from it.
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

  // ── Core download logic ───────────────────────────────────────────────────

  Future<void> _runDownload(
      DownloadModel model, String mediaType, int partCount) async {
    try {
      final dir = await _getDownloadsDir();

      // ── Build download URLs ──────────────────────────────────────────────
      final List<String> downloadUrls = [];
      if (partCount <= 1) {
        final endpoint = mediaType == 'episode'
            ? ApiConstants.episodeDownload(model.mediaId)
            : ApiConstants.songDownload(model.mediaId);
        downloadUrls.add('${ApiConstants.baseUrl}$endpoint');
      } else {
        final streamEndpoint = mediaType == 'episode'
            ? ApiConstants.episodeStream(model.mediaId)
            : ApiConstants.songStream(model.mediaId);
        for (int i = 1; i <= partCount; i++) {
          downloadUrls
              .add('${ApiConstants.baseUrl}$streamEndpoint?part=$i');
        }
      }

      // ── Download → encrypt each part independently ──────────────────────
      //
      // KEY CHANGE: We no longer merge parts into one file.
      // Each part is downloaded to a temp file, encrypted to its own
      // per-part encrypted file, then the temp file is deleted.
      // This preserves the MP3 file headers of each part intact so
      // ExoPlayer can correctly read each part's duration independently.

      for (int i = 0; i < downloadUrls.length; i++) {
        final tmpPath = '${dir.path}/${model.mediaId}_part$i.tmp';
        final partEncPath =
            _partEncPath(model.encryptedFilePath, i);

        // Delete stale files from previous failed attempts
        final tmpFile = File(tmpPath);
        if (await tmpFile.exists()) await tmpFile.delete();
        final partEncFile = File(partEncPath);
        if (await partEncFile.exists()) await partEncFile.delete();

        // Download this part
        await _dio.download(
          downloadUrls[i],
          tmpPath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final partProgress = received / total;
              // 0–85% = downloading phase across all parts
              final overallProgress =
                  (i + partProgress) / downloadUrls.length * 0.85;
              _updateProgress(
                model,
                'downloading',
                overallProgress.clamp(0.01, 0.85),
                i + 1,
              );
            }
          },
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: true,
            receiveTimeout: const Duration(minutes: 10),
            validateStatus: (status) => status != null && status < 300,
          ),
        );

        // Verify download is non-empty
        final downloaded = File(tmpPath);
        if (!await downloaded.exists() || await downloaded.length() == 0) {
          throw Exception(
              'Downloaded part $i is empty — server may have returned an error body');
        }

        // Encrypt this part to its own file (85–100% phase)
        _updateProgress(
          model,
          'encrypting',
          0.85 + (i + 0.5) / downloadUrls.length * 0.15,
          i + 1,
        );
        await _encryptionService.encryptFile(tmpPath, partEncPath);

        // Delete temp file immediately — save storage
        try {
          await File(tmpPath).delete();
        } catch (_) {}

        model.downloadedParts = i + 1;
        _updateState(model);
      }

      // ── For backwards-compat: also write a single _enc.bin for 1-part ──
      // (old _playOffline code reads model.encryptedFilePath directly for
      //  single-part items.  For multi-part we read the per-part files.)
      // Nothing to do — _partEncPath(baseEncPath, 0) IS the only file for
      // single-part downloads; the base _enc.bin is never written anymore.
      // getDecryptedPath() handles both layouts (see below).

      // ── Compute total encrypted size ─────────────────────────────────────
      int totalSize = 0;
      for (int i = 0; i < downloadUrls.length; i++) {
        final f = File(_partEncPath(model.encryptedFilePath, i));
        if (await f.exists()) totalSize += await f.length();
      }

      model.fileSizeBytes = totalSize;
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
        errorMessage = e.message?.isNotEmpty == true
            ? e.message!
            : 'Network error — tap to retry';
      }
      _markFailed(model, errorMessage);
    } catch (e) {
      _markFailed(model, e.toString().replaceAll('Exception: ', ''));
    }
  }

  // ── getDecryptedPath (single-part) — kept for compatibility ──────────────

  /// Returns the decrypted path for a SINGLE-PART download.
  /// Use [getDecryptedPaths] for multi-part downloads.
  Future<String?> getDecryptedPath(String mediaId) async {
    final paths = await getDecryptedPaths(mediaId);
    return paths?.first;
  }

  /// Returns the list of decrypted local file paths for ALL parts of a
  /// completed download, in order.  Returns null if the download is not
  /// completed or any decryption fails.
  Future<List<String>?> getDecryptedPaths(String mediaId) async {
    final download = state[mediaId];
    if (download == null || !download.isCompleted) return null;

    try {
      final totalParts = download.totalParts;
      final results = <String>[];

      if (totalParts <= 1) {
        // ── Single-part: check new per-part layout first, then legacy ──────
        final newPartPath = _partEncPath(download.encryptedFilePath, 0);
        final legacyPath = download.encryptedFilePath;

        if (File(newPartPath).existsSync()) {
          results.add(
              await _encryptionService.decryptToTemp(newPartPath));
        } else if (File(legacyPath).existsSync()) {
          // Legacy single-file download (pre-fix)
          results.add(
              await _encryptionService.decryptToTemp(legacyPath));
        } else {
          return null; // file missing
        }
      } else {
        // ── Multi-part: decrypt each part file ───────────────────────────
        for (int i = 0; i < totalParts; i++) {
          final partEncPath =
              _partEncPath(download.encryptedFilePath, i);
          if (!File(partEncPath).existsSync()) {
            // A part file is missing — download is corrupt
            return null;
          }
          results.add(
              await _encryptionService.decryptToTemp(partEncPath));
        }
      }

      return results;
    } catch (_) {
      return null;
    }
  }

  // ── deleteDownload ────────────────────────────────────────────────────────

  Future<void> deleteDownload(String mediaId) async {
    final download = state[mediaId];
    if (download == null) return;

    // Delete all per-part encrypted files
    final totalParts =
        download.totalParts <= 0 ? 1 : download.totalParts;
    for (int i = 0; i < totalParts; i++) {
      try {
        final f = File(_partEncPath(download.encryptedFilePath, i));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    // Also delete legacy single-file if it exists
    try {
      final legacy = File(download.encryptedFilePath);
      if (await legacy.exists()) await legacy.delete();
    } catch (_) {}

    final newState = Map<String, DownloadModel>.from(state);
    newState.remove(mediaId);
    state = newState;
    try {
      final box = Hive.box(AppConstants.downloadsBox);
      box.delete('dl_$mediaId');
    } catch (_) {}
  }

  // ── Private helpers ───────────────────────────────────────────────────────

  void _markFailed(DownloadModel model, String message) {
    model.status = 'failed';
    model.errorMessage = message;
    model.progress = 0.0;
    _updateState(model);
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
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}

// ── Providers ─────────────────────────────────────────────────────────────────

final encryptionServiceProvider = Provider<EncryptionService>((ref) {
  return EncryptionService();
});

final downloadManagerProvider =
    StateNotifierProvider<DownloadManager, Map<String, DownloadModel>>(
        (ref) {
  final encService = ref.watch(encryptionServiceProvider);
  return DownloadManager(encService);
});