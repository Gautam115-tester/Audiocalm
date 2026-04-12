// lib/core/network/dio_client.dart
//
// CHANGES:
// 1. followRedirects: true + maxRedirects: 5
//    The backend now sends 302 redirects to Telegram CDN for all stream URLs.
//    Dio must follow these redirects to reach the audio content.
//
// 2. receiveTimeout: 45s (unchanged — still needed for cold-start tolerance)
//
// 3. In-flight request deduplication (unchanged — prevents parallel floods)
//
// 4. X-Force-Refresh header support:
//    When a stream request fails with 401/403 (expired Telegram signed URL),
//    the caller can retry with the X-Force-Refresh header set to '1'.
//    The backend will then force-evict its URL cache and re-resolve from
//    Telegram before sending a fresh redirect.
//
// NOTE: just_audio handles its own HTTP redirects internally and does NOT
// use this DioClient for stream requests. This client is only used for
// API calls (metadata, album lists, etc.). Stream URLs are handled by
// just_audio's built-in HTTP client which follows redirects by default.

import 'dart:async';
import 'package:dio/dio.dart';
import '../constants/api_constants.dart';
import '../errors/app_exceptions.dart';

class DioClient {
  late final Dio _dio;

  // In-flight deduplication: same URL → same Future, no duplicate requests
  final Map<String, Future<dynamic>> _inFlight = {};

  static DioClient? _instance;
  factory DioClient() {
    _instance ??= DioClient._internal();
    return _instance!;
  }

  DioClient._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl:        ApiConstants.baseUrl,
        connectTimeout: const Duration(milliseconds: ApiConstants.connectTimeout),
        receiveTimeout: const Duration(seconds: 45),
        // Must follow redirects — backend sends 302 to Telegram CDN
        followRedirects: true,
        maxRedirects:    5,
        headers: {
          'Content-Type': 'application/json',
          'Accept':       'application/json',
          'Connection':   'keep-alive',
        },
        responseType: ResponseType.json,
        // Validate all 2xx and 3xx as success
        // (Dio's redirect handling uses this internally)
        validateStatus: (status) => status != null && status < 400,
      ),
    );

    // Compact single-line debug logger
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
  }

  Dio get dio => _dio;

  /// GET with in-flight deduplication.
  /// If an identical [path]+[queryParameters] request is already in-flight,
  /// returns the same Future — no duplicate network call.
  Future<T> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    final key = _buildKey(path, queryParameters);

    if (_inFlight.containsKey(key)) {
      return await (_inFlight[key] as Future<T>);
    }

    final future = _doGet<T>(path,
        queryParameters: queryParameters, options: options);

    _inFlight[key] = future;

    try {
      final result = await future;
      return result;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// GET with forced cache refresh — used after a 401 from Telegram CDN.
  /// Appends X-Force-Refresh: 1 header so the backend evicts its URL cache.
  Future<T> getRefreshed<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    return _doGet<T>(
      path,
      queryParameters: queryParameters,
      options: Options(
        headers: {'X-Force-Refresh': '1'},
      ),
    );
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