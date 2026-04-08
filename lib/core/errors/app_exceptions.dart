// lib/core/errors/app_exceptions.dart

sealed class AppException implements Exception {
  final String message;
  final String? code;
  const AppException(this.message, {this.code});

  @override
  String toString() => 'AppException: $message';
}

class NetworkException extends AppException {
  final int? statusCode;
  const NetworkException(super.message, {this.statusCode, super.code});
}

class ConnectionException extends AppException {
  const ConnectionException(super.message);
}

class TimeoutException extends AppException {
  const TimeoutException(super.message);
}

class ServerException extends AppException {
  const ServerException(super.message, {super.code});
}

class NotFoundException extends AppException {
  const NotFoundException(super.message);
}

class EncryptionException extends AppException {
  const EncryptionException(super.message);
}

class DecryptionException extends AppException {
  const DecryptionException(super.message);
}

class StorageException extends AppException {
  const StorageException(super.message);
}

class DownloadException extends AppException {
  const DownloadException(super.message);
}

class AudioException extends AppException {
  const AudioException(super.message);
}

class PermissionException extends AppException {
  const PermissionException(super.message);
}

class UnknownException extends AppException {
  const UnknownException(super.message);
}

// Result type
sealed class Result<T> {
  const Result();
}

class Success<T> extends Result<T> {
  final T data;
  const Success(this.data);
}

class Failure<T> extends Result<T> {
  final AppException exception;
  const Failure(this.exception);
}

extension ResultExtension<T> on Result<T> {
  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  T? get dataOrNull => switch (this) {
        Success<T> s => s.data,
        Failure<T> _ => null,
      };

  AppException? get errorOrNull => switch (this) {
        Success<T> _ => null,
        Failure<T> f => f.exception,
      };

  R fold<R>({
    required R Function(T data) onSuccess,
    required R Function(AppException error) onFailure,
  }) =>
      switch (this) {
        Success<T> s => onSuccess(s.data),
        Failure<T> f => onFailure(f.exception),
      };
}
