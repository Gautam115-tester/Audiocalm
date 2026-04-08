// lib/features/downloads/data/services/encryption_service.dart

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

  Future<void> init() async {
    if (_initialized) return;
    _key = await _getOrCreateKey();
    _initialized = true;
  }

  Future<enc.Key> _getOrCreateKey() async {
    try {
      final stored = await _storage.read(key: AppConstants.encryptionKeyAlias);
      if (stored != null) {
        final bytes = Uint8List.fromList(
          stored.split(',').map(int.parse).toList(),
        );
        return enc.Key(bytes);
      }
    } catch (_) {}

    // Generate new 256-bit key
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

  Future<void> encryptFile(String inputPath, String outputPath) async {
    await init();

    try {
      final inputFile = File(inputPath);
      if (!await inputFile.exists()) {
        throw EncryptionException('Input file not found: $inputPath');
      }

      final inputBytes = await inputFile.readAsBytes();

      // Generate random IV per file
      final random = Random.secure();
      final ivBytes = Uint8List.fromList(
        List.generate(16, (_) => random.nextInt(256)),
      );
      final iv = enc.IV(ivBytes);

      final encrypter = enc.Encrypter(
        enc.AES(_key, mode: enc.AESMode.cbc),
      );

      final encrypted = encrypter.encryptBytes(inputBytes, iv: iv);

      // Write: [IV (16 bytes)] + [encrypted data]
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

  Future<String> decryptToTemp(String encryptedPath) async {
    await init();

    try {
      final encryptedFile = File(encryptedPath);
      if (!await encryptedFile.exists()) {
        throw DecryptionException('Encrypted file not found: $encryptedPath');
      }

      final allBytes = await encryptedFile.readAsBytes();
      if (allBytes.length < 16) {
        throw DecryptionException('Invalid encrypted file: too short');
      }

      // Extract IV (first 16 bytes) and ciphertext
      final ivBytes = Uint8List.fromList(allBytes.sublist(0, 16));
      final cipherBytes = Uint8List.fromList(allBytes.sublist(16));

      final iv = enc.IV(ivBytes);
      final encrypter = enc.Encrypter(
        enc.AES(_key, mode: enc.AESMode.cbc),
      );

      final decrypted = encrypter.decryptBytes(
        enc.Encrypted(cipherBytes),
        iv: iv,
      );

      // Write to temp cache directory
      final cacheDir = await _getCacheDir();
      final fileName =
          '${encryptedPath.split('/').last.replaceAll('.enc', '')}_dec.m4a';
      final tempPath = '${cacheDir.path}/$fileName';

      final tempFile = File(tempPath);
      await tempFile.writeAsBytes(decrypted);

      return tempPath;
    } catch (e) {
      if (e is DecryptionException) rethrow;
      throw DecryptionException('Decryption failed: $e');
    }
  }

  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final cacheDir =
        Directory('${appDir.path}/${AppConstants.decryptedCacheDir}');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir;
  }

  Future<void> clearDecryptedCache() async {
    try {
      final cacheDir = await _getCacheDir();
      if (await cacheDir.exists()) {
        await for (final file in cacheDir.list()) {
          if (file is File) {
            await file.delete();
          }
        }
      }
    } catch (_) {}
  }

  Future<void> clearExpiredCache() async {
    try {
      final cacheDir = await _getCacheDir();
      if (!await cacheDir.exists()) return;

      final cutoff = DateTime.now()
          .subtract(Duration(hours: AppConstants.decryptedCacheDurationHours));

      await for (final entity in cacheDir.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}
  }
}
