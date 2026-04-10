// lib/core/network/dio_client.dart
//
// FIXES:
// 1. Increased receiveTimeout from 15s → 45s so Render free-tier cold-starts
//    don't cause cascading timeout failures on every album detail request.
// 2. Added in-flight request deduplication: if the same URL is already being
//    fetched, subsequent callers await the same Future instead of firing a
//    duplicate request. This is the PRIMARY fix for the 22-concurrent-request
//    flood seen in the logs (11 albums × 2 = 22 requests all at once).
// 3. Kept the compact single-line logger (no LogInterceptor banner spam).

import 'dart:async';
import 'package:dio/dio.dart';
import '../constants/api_constants.dart';
import '../errors/app_exceptions.dart';

class DioClient {
  late final Dio _dio;

  // ── In-flight deduplication ───────────────────────────────────────────────
  // Key: full URL string. Value: the pending Future for that request.
  // When a second caller asks for the same URL while the first is still
  // in-flight, they share the same Future — zero duplicate network requests.
  final Map<String, Future<dynamic>> _inFlight = {};

  static DioClient? _instance;
  factory DioClient() {
    _instance ??= DioClient._internal();
    return _instance!;
  }

  DioClient._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.baseUrl,
        connectTimeout: const Duration(milliseconds: ApiConstants.connectTimeout),
        // FIX: was 15 000 ms — too short for Render free-tier cold starts.
        // Render free instances spin down after 15 min of inactivity and take
        // up to 50 s to cold-start. 45 s gives them a realistic chance.
        receiveTimeout: const Duration(seconds: 45),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Connection': 'keep-alive',
        },
        responseType: ResponseType.json,
      ),
    );

    // Compact single-line logger — no LogInterceptor banner flood.
    assert(() {
      _dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            // ignore: avoid_print
            print('[HTTP →] ${options.method} ${options.uri}');
            handler.next(options);
          },
          onResponse: (response, handler) {
            // ignore: avoid_print
            print('[HTTP ←] ${response.statusCode} ${response.realUri}');
            handler.next(response);
          },
          onError: (err, handler) {
            // ignore: avoid_print
            print('[HTTP ✗] ${err.requestOptions.uri} — ${err.message}');
            handler.next(err);
          },
        ),
      );
      return true;
    }());

    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) {
          handler.next(error);
        },
      ),
    );
  }

  Dio get dio => _dio;

  /// GET with in-flight deduplication.
  ///
  /// If an identical [path] + [queryParameters] request is already pending,
  /// this returns the same Future — no duplicate network call is made.
  /// The dedup key is cleared as soon as the first request completes
  /// (success or error), so the next independent call goes through normally.
  Future<T> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    // Build a stable cache key from path + sorted query params
    final key = _buildKey(path, queryParameters);

    if (_inFlight.containsKey(key)) {
      // Another caller is already fetching this — join their Future.
      return await (_inFlight[key] as Future<T>);
    }

    final future = _doGet<T>(path,
        queryParameters: queryParameters, options: options);

    _inFlight[key] = future;

    try {
      final result = await future;
      return result;
    } finally {
      // Always clear the in-flight entry so future independent calls work.
      _inFlight.remove(key);
    }
  }

  Future<T> _doGet<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    try {
      final response = await _dio.get(
        path,
        queryParameters: queryParameters,
        options: options,
      );
      return response.data as T;
    } on DioException catch (e) {
      throw _handleDioError(e);
    } catch (e) {
      throw UnknownException(e.toString());
    }
  }

  String _buildKey(String path, Map<String, dynamic>? queryParameters) {
    if (queryParameters == null || queryParameters.isEmpty) return path;
    final sorted = queryParameters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final qs = sorted.map((e) => '${e.key}=${e.value}').join('&');
    return '$path?$qs';
  }

  AppException _handleDioError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const TimeoutException('Connection timed out');
      case DioExceptionType.connectionError:
        return const ConnectionException('No internet connection');
      case DioExceptionType.badResponse:
        final statusCode = error.response?.statusCode;
        if (statusCode == 404) {
          return const NotFoundException('Resource not found');
        } else if (statusCode != null && statusCode >= 500) {
          return const ServerException('Server error occurred');
        }
        return NetworkException(
          error.response?.statusMessage ?? 'Network error',
          statusCode: statusCode,
        );
      default:
        return UnknownException(error.message ?? 'Unknown error');
    }
  }
}