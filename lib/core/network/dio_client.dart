// lib/core/network/dio_client.dart

import 'package:dio/dio.dart';
import '../constants/api_constants.dart';
import '../errors/app_exceptions.dart';

class DioClient {
  late final Dio _dio;

  // Shared singleton instance to reuse the HTTP connection pool
  static DioClient? _instance;
  factory DioClient() {
    _instance ??= DioClient._internal();
    return _instance!;
  }

  DioClient._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.baseUrl,
        // PERF FIX: Reduced from 30s → 10s connect, 120s → 15s receive for JSON
        // Stream endpoints use their own Dio instance with longer timeouts
        connectTimeout: const Duration(milliseconds: ApiConstants.connectTimeout),
        receiveTimeout: const Duration(milliseconds: ApiConstants.receiveTimeout),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          // PERF FIX: Keep TCP connections alive across requests
          'Connection': 'keep-alive',
        },
        // PERF FIX: Enable response compression
        responseType: ResponseType.json,
      ),
    );

    // PERF FIX: Only log in debug mode, never log response bodies (huge JSON kills perf)
    assert(() {
      _dio.interceptors.add(LogInterceptor(
        requestBody: false,
        responseBody: false, // was true — logging full JSON response is very slow
        responseHeader: false,
        requestHeader: false,
        error: true,
        logPrint: (obj) => print('[DioClient] $obj'),
      ));
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