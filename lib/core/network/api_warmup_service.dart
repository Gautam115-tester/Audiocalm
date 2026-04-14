// lib/core/network/api_warmup_service.dart
//
// FIXES:
// 1. Warms up the backend server on app start (prevents cold-start failures)
// 2. Retries failed requests with exponential backoff
// 3. Pre-fetches health check so Render server is warm before data requests

import 'dart:async';
import 'package:flutter/foundation.dart';
import '../constants/api_constants.dart';
import 'dio_client.dart';

class ApiWarmupService {
  static final ApiWarmupService _instance = ApiWarmupService._();
  factory ApiWarmupService() => _instance;
  ApiWarmupService._();

  bool _warmed = false;
  Completer<void>? _warmupCompleter;

  /// Call this as early as possible (in main or splash) to wake the Render server.
  /// Subsequent calls return the same Future immediately.
  Future<void> ensureWarmed(DioClient dio) async {
    if (_warmed) return;
    if (_warmupCompleter != null) return _warmupCompleter!.future;

    _warmupCompleter = Completer<void>();
    _doWarmup(dio).then((_) {
      _warmed = true;
      _warmupCompleter!.complete();
    }).catchError((e) {
      // Non-fatal — app continues even if warmup fails
      debugPrint('[ApiWarmup] Warmup failed: $e');
      _warmed = true; // don't retry forever
      _warmupCompleter!.complete();
    });
    return _warmupCompleter!.future;
  }

  Future<void> _doWarmup(DioClient dio) async {
    // Fire health check first (lightweight, wakes the server)
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        await dio.get<dynamic>(ApiConstants.health)
            .timeout(const Duration(seconds: 15));
        debugPrint('[ApiWarmup] Server warm after ${attempt + 1} attempt(s)');
        return;
      } catch (e) {
        if (attempt < 2) {
          // Exponential backoff: 1s, 2s
          await Future.delayed(Duration(seconds: attempt + 1));
        }
      }
    }
  }

  /// Fetch with automatic retry (up to [maxAttempts]) and exponential backoff.
  static Future<T> fetchWithRetry<T>(
    Future<T> Function() fetch, {
    int maxAttempts = 3,
    Duration initialDelay = const Duration(seconds: 1),
  }) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await fetch();
      } catch (e) {
        if (attempt == maxAttempts - 1) rethrow;
        final delay = initialDelay * (attempt + 1);
        debugPrint('[ApiWarmup] Retry ${attempt + 1}/$maxAttempts after ${delay.inSeconds}s: $e');
        await Future.delayed(delay);
      }
    }
    throw StateError('Should not reach here');
  }
}