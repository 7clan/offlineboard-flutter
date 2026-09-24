import 'dart:io' show SocketException;

import 'package:dio/dio.dart';

import 'app_exception.dart';

/// Translates transport-level failures into domain [AppException]s.
///
/// This is the single place where Dio/HTTP jargon is converted into
/// user-safe errors — controllers and widgets only ever see `AppException`.
abstract final class ErrorMapper {
  /// Maps [error] (typically a [DioException]) to an [AppException].
  ///
  /// Already-mapped [AppException]s pass through untouched, so callers can
  /// wrap any `catch` in a single call.
  static AppException map(Object error, {StackTrace? stackTrace}) {
    if (error is AppException) return error;

    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return TimeoutException(cause: error, stackTrace: stackTrace);
        case DioExceptionType.connectionError:
          return NetworkException(cause: error, stackTrace: stackTrace);
        case DioExceptionType.badResponse:
          return _mapBadResponse(error, stackTrace);
        case DioExceptionType.cancel:
          return CancelledException(cause: error, stackTrace: stackTrace);
        case DioExceptionType.badCertificate:
          return UnknownException(cause: error, stackTrace: stackTrace);
        case DioExceptionType.unknown:
          return _unwrapUnknown(error, stackTrace);
      }
    }

    if (error is FormatException || error is TypeError) {
      return MalformedResponseException(cause: error, stackTrace: stackTrace);
    }

    if (error is SocketException) {
      return NetworkException(cause: error, stackTrace: stackTrace);
    }

    return UnknownException(cause: error, stackTrace: stackTrace);
  }

  static AppException _mapBadResponse(DioException error, StackTrace? stack) {
    final status = error.response?.statusCode ?? 0;
    final body = error.response?.data;
    final Map<String, dynamic> json = body is Map<String, dynamic>
        ? body
        : const <String, dynamic>{};

    switch (status) {
      case 401:
        return UnauthorizedException(
          serverMessage: _serverMessage(json),
          cause: error,
          stackTrace: stack,
        );
      case 409:
        return ConflictException(cause: error, stackTrace: stack);
      default:
        return ServerException(
          statusCode: status,
          serverMessage: _serverMessage(json),
          cause: error,
          stackTrace: stack,
        );
    }
  }

  /// Extracts the server's user-facing message when it supplies one.
  static String? _serverMessage(Map<String, dynamic> json) {
    final message = json['message'];
    return message is String && message.trim().isNotEmpty ? message : null;
  }

  /// Dio sometimes wraps adapter-level exceptions as `unknown` with the
  /// original error nested inside — unwrap before deciding.
  static AppException _unwrapUnknown(DioException error, StackTrace? stack) {
    Object? cause = error.error;
    while (cause is DioException) {
      switch (cause.type) {
        case DioExceptionType.connectionError:
          return NetworkException(cause: cause, stackTrace: stack);
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
          return TimeoutException(cause: cause, stackTrace: stack);
        default:
          break;
      }
      cause = cause.error;
    }
    if (cause is SocketException) {
      return NetworkException(cause: cause, stackTrace: stack);
    }
    if (cause is FormatException || cause is TypeError) {
      return MalformedResponseException(cause: cause, stackTrace: stack);
    }
    return UnknownException(cause: error, stackTrace: stack);
  }
}
