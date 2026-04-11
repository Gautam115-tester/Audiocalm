// lib/features/downloads/data/services/encryption_service.dart
//
// THREAD FIX — Added isolate-safe API for background encryption/decryption
// =========================================================================
//
// NEW METHODS:
//   initWithKeyBytes(String)   — initialize from a pre-exported key string
//                                (safe to call inside an Isolate where
//                                FlutterSecureStorage is not available)
//   getKeyBytesString()        — export the key as a comma-separated string
//                                so it can be passed across isolate boundaries
//   decryptToTempInDir(path, dir) — decrypt to a specific cache dir path
//                                (needed when the isolate cannot call
//                                getApplicationDocumentsDirectory())
//
// All existing methods (encryptFile, decryptToTemp, clearDecryptedCache,
// clearExpiredCache) are unchanged and still work on the main isolate.

import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/errors/app_exceptions.dart';

class EncryptionService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  late enc.Key _key;
  bool _initialized = false;

  // ── Main-isolate init (reads from FlutterSecureStorage) ──────────────────

  Future<void> init() async {
    if (_initialized) return;
    _key = await _getOrCreateKey();
    _initialized = true;
  }

  /// Export the current key as a comma-separated byte string so it can be
  /// passed to a background isolate via SendPort (which cannot carry objects
  /// like enc.Key but can carry primitive Strings).
  Future<String?> getKeyBytesString() async {
    try {
      await init();
      return _key.bytes.join(',');
    } catch (_) {
      return null;
    }
  }

  // ── Isolate-safe init (does NOT use FlutterSecureStorage) ─────────────────

  /// Initialize from a previously-exported key string.
  /// Call this inside background isolates where FlutterSecureStorage is
  /// unavailable (it requires platform channels).
  Future<void> initWithKeyBytes(String keyBytesString) async {
    if (_initialized) return;
    try {
      final bytes = Uint8List.fromList(
        keyBytesString.split(',').map(int.parse).toList(),
      );
      _key = enc.Key(bytes);
      _initialized = true;
    } catch (e) {
      throw EncryptionException('Failed to init from key bytes: $e');
    }
  }

  // ── Key management (main isolate only) ────────────────────────────────────

  Future<enc.Key> _getOrCreateKey() async {
    try {
      final stored =
          await _storage.read(key: AppConstants.encryptionKeyAlias);
      if (stored != null) {
        final bytes = Uint8List.fromList(
          stored.split(',').map(int.parse).toList(),
        );
        return enc.Key(bytes);
      }
    } catch (_) {}

    final random = Random.secure();
    final keyBytes = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    await _storage.write(
      key: AppConstants.encryptionKeyAlias,
      value: keyBytes.join(','),
    );
    return enc.Key(keyBytes);
  }

  // ── encryptFile ────────────────────────────────────────────────────────────

  Future<void> encryptFile(String inputPath, String outputPath) async {
    await init();
    try {
      final inputFile = File(inputPath);
      if (!inputFile.existsSync()) {
        throw EncryptionException('Input file not found: $inputPath');
      }
      final inputBytes = await inputFile.readAsBytes();
      final random = Random.secure();
      final ivBytes = Uint8List.fromList(
        List.generate(16, (_) => random.nextInt(256)),
      );
      final iv = enc.IV(ivBytes);
      final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
      final encrypted = encrypter.encryptBytes(inputBytes, iv: iv);

      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      final sink = outputFile.openWrite();
      sink.add(ivBytes);
      sink.add(encrypted.bytes);
      await sink.close();
    } catch (e) {
      if (e is EncryptionException) rethrow;
      throw EncryptionException('Encryption failed: $e');
    }
  }

  // ── decryptToTemp (main isolate — resolves cache dir via path_provider) ───

  Future<String> decryptToTemp(String encryptedPath) async {
    await init();
    final cacheDir = await _getCacheDir();
    return _decryptCore(encryptedPath, cacheDir.path);
  }

  // ── decryptToTempInDir (isolate-safe — caller provides the cache dir) ─────
  //
  // Used by download_manager.dart when decrypting inside a background isolate
  // where getApplicationDocumentsDirectory() may not be available.

  Future<String> decryptToTempInDir(
      String encryptedPath, String cacheDirPath) async {
    if (!_initialized) {
      throw DecryptionException(
          'EncryptionService not initialised — call initWithKeyBytes() first');
    }
    return _decryptCore(encryptedPath, cacheDirPath);
  }

  // ── Core decrypt logic (shared) ────────────────────────────────────────────

  Future<String> _decryptCore(String encryptedPath, String cacheDirPath) async {
    try {
      final encryptedFile = File(encryptedPath);
      if (!encryptedFile.existsSync()) {
        throw DecryptionException(
            'Encrypted file not found: $encryptedPath');
      }
      final allBytes = await encryptedFile.readAsBytes();
      if (allBytes.length < 16) {
        throw DecryptionException('Invalid encrypted file: too short');
      }

      final ivBytes = Uint8List.fromList(allBytes.sublist(0, 16));
      final cipherBytes = Uint8List.fromList(allBytes.sublist(16));
      final iv = enc.IV(ivBytes);
      final encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
      final decrypted = encrypter.decryptBytes(
        enc.Encrypted(cipherBytes),
        iv: iv,
      );

      final encBasename = encryptedPath
          .split('/')
          .last
          .replaceAll(RegExp(r'\.[^.]+$'), '');

      final cacheDir = Directory(cacheDirPath);
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);

      final tempPath = '$cacheDirPath/${encBasename}_dec.audio';
      final cached = File(tempPath);
      if (cached.existsSync() && cached.lengthSync() > 0) {
        return tempPath;
      }
      await cached.writeAsBytes(decrypted);
      return tempPath;
    } catch (e) {
      if (e is DecryptionException) rethrow;
      throw DecryptionException('Decryption failed: $e');
    }
  }

  // ── Cache helpers ──────────────────────────────────────────────────────────

  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir =
        Directory('${appDir.path}/${AppConstants.decryptedCacheDir}');
    if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
    return cacheDir;
  }

  Future<void> clearDecryptedCache() async {
    try {
      final cacheDir = await _getCacheDir();
      if (cacheDir.existsSync()) {
        await for (final file in cacheDir.list()) {
          if (file is File) await file.delete();
        }
      }
    } catch (_) {}
  }

  Future<void> clearExpiredCache() async {
    try {
      final cacheDir = await _getCacheDir();
      if (!cacheDir.existsSync()) return;
      final cutoff = DateTime.now().subtract(
        Duration(hours: AppConstants.decryptedCacheDurationHours),
      );
      await for (final entity in cacheDir.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) await entity.delete();
        }
      }
    } catch (_) {}
  }
}