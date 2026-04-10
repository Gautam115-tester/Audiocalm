// lib/core/network/dio_client.dart

import 'package:dio/dio.dart';
import '../constants/api_constants.dart';
import '../errors/app_exceptions.dart';

class DioClient {
  late final Dio _dio;

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
        receiveTimeout: const Duration(milliseconds: ApiConstants.receiveTimeout),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Connection': 'keep-alive',
        },
        responseType: ResponseType.json,
      ),
    );

    // FIX: Replace LogInterceptor entirely in debug mode.
    // LogInterceptor always prints "*** Request ***" / "*** Response ***" banners
    // even when requestBody/responseBody are false — this floods logcat and
    // contributes to BLASTBufferQueue frame pressure on low-end devices.
    // Use a minimal custom interceptor that only logs the URI + status code.
    assert(() {
      _dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            // Single compact line per request — no multi-line banner spam
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

  Future<T> get<T>(
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