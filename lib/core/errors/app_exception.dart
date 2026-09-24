/// Base type for every failure the UI may need to present.
///
/// Repositories and services translate low-level transport / HTTP / database
/// errors into these user-safe types so widgets never see raw stack traces.
sealed class AppException implements Exception {
  /// Creates an exception carrying the original [cause] for logging — never
  /// shown to users.
  const AppException({this.cause, this.stackTrace});

  /// Original error, kept for logging — never displayed.
  final Object? cause;

  /// Stack trace of the original error, if captured.
  final StackTrace? stackTrace;

  /// Human-readable, non-technical message safe to show in the UI.
  String get userMessage;

  @override
  String toString() => '$runtimeType(${cause ?? ''})';
}

/// The device is offline or the server cannot be reached at all.
class NetworkException extends AppException {
  /// Creates a network-unreachable exception.
  const NetworkException({super.cause, super.stackTrace});

  @override
  String get userMessage =>
      'You appear to be offline. Changes are saved locally and will sync '
      'when you reconnect.';
}

/// The request took longer than the configured timeout.
class TimeoutException extends AppException {
  /// Creates a timeout exception.
  const TimeoutException({super.cause, super.stackTrace});

  @override
  String get userMessage =>
      'The sync server is taking too long to respond. Please try again.';
}

/// Missing or expired credentials (HTTP 401).
class UnauthorizedException extends AppException {
  /// Creates an unauthorized exception, optionally carrying a server-provided
  /// user-safe [serverMessage].
  const UnauthorizedException({
    this.serverMessage,
    super.cause,
    super.stackTrace,
  });

  /// User-safe message supplied by the API, when present.
  final String? serverMessage;

  @override
  String get userMessage =>
      serverMessage ?? 'Your session has expired. Please sign in again.';
}

/// Server-side failure (HTTP 5xx).
class ServerException extends AppException {
  /// Creates a server exception.
  const ServerException({
    this.statusCode,
    this.serverMessage,
    super.cause,
    super.stackTrace,
  });

  /// HTTP status code, when known.
  final int? statusCode;

  /// User-safe message supplied by the API, when present.
  final String? serverMessage;

  @override
  String get userMessage =>
      serverMessage ?? 'Something went wrong on our side. Please try again.';
}

/// The response could not be decoded / parsed into the expected shape.
class MalformedResponseException extends AppException {
  /// Creates a malformed-response exception.
  const MalformedResponseException({super.cause, super.stackTrace});

  @override
  String get userMessage =>
      'We received an unexpected response from the sync server.';
}

/// The server rejected a mutation because of a conflicting version.
///
/// This is *expected* behaviour in the offline sync flow (the sync engine
/// resolves it); it becomes a user-visible error only when it escapes the
/// engine.
class ConflictException extends AppException {
  /// Creates a conflict exception.
  const ConflictException({super.cause, super.stackTrace});

  @override
  String get userMessage =>
      'This was changed elsewhere. The newest change was kept.';
}

/// The request was cancelled before completing.
class CancelledException extends AppException {
  /// Creates a cancelled exception.
  const CancelledException({super.cause, super.stackTrace});

  @override
  String get userMessage => 'The request was cancelled.';
}

/// The local SQLite database failed.
class DatabaseException extends AppException {
  /// Creates a local-database exception.
  const DatabaseException({super.cause, super.stackTrace});

  @override
  String get userMessage =>
      'A local storage problem occurred. Your data is safe — please try '
      'again.';
}

/// Anything unexpected — the safe fallback.
class UnknownException extends AppException {
  /// Creates an unknown exception.
  const UnknownException({super.cause, super.stackTrace});

  @override
  String get userMessage => 'Something went wrong. Please try again.';
}
