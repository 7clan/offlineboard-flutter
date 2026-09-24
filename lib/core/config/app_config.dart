import 'dart:math' as math;

/// Application-wide configuration: remote endpoint, timeouts and the sync
/// retry policy.
///
/// Anything a test might want to tune travels through this class (or through
/// the injectable [Clock]/`IdGenerator`), never through magic constants
/// buried in business logic.
class AppConfig {
  /// Creates a configuration.
  const AppConfig({
    this.baseUrl = defaultBaseUrl,
    this.connectTimeout = const Duration(seconds: 8),
    this.receiveTimeout = const Duration(seconds: 20),
    this.pushBatchSize = 32,
    this.retryPolicy = const SyncRetryPolicy(),
  });

  /// Fallback base URL. The app wiring points the client at the in-process
  /// mock sync server (which binds an ephemeral port), so this value only
  /// matters for tests that construct a client without a server.
  static const String defaultBaseUrl = 'http://127.0.0.1:8420';

  /// Base URL of the sync server.
  final String baseUrl;

  /// Dio connection timeout for sync requests.
  final Duration connectTimeout;

  /// Dio receive timeout for sync responses.
  final Duration receiveTimeout;

  /// Maximum number of queued mutations pushed per request.
  ///
  /// Batching keeps requests small and lets conflicts resolve per mutation.
  final int pushBatchSize;

  /// Retry behaviour for pushes that fail at the transport level.
  final SyncRetryPolicy retryPolicy;

  AppConfig copyWith({
    String? baseUrl,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    int? pushBatchSize,
    SyncRetryPolicy? retryPolicy,
  }) {
    return AppConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      pushBatchSize: pushBatchSize ?? this.pushBatchSize,
      retryPolicy: retryPolicy ?? this.retryPolicy,
    );
  }
}

/// Exponential backoff policy for the sync engine.
///
/// * [initialBackoff] — wait before the first retry.
/// * [backoffMultiplier] — growth factor per failed attempt.
/// * [maxBackoff] — cap, so retries stay civil.
/// * [maxAttempts] — after this many failed attempts the mutation is
///   surfaced as `SyncStatus.failed` (it stays in the queue for a manual
///   retry instead of being dropped).
class SyncRetryPolicy {
  /// Creates a policy.
  const SyncRetryPolicy({
    this.initialBackoff = const Duration(seconds: 1),
    this.backoffMultiplier = 2.0,
    this.maxBackoff = const Duration(minutes: 2),
    this.maxAttempts = 5,
  });

  final Duration initialBackoff;
  final double backoffMultiplier;
  final Duration maxBackoff;
  final int maxAttempts;

  /// Delay before attempt `attempts + 1`, given how many attempts have
  /// already failed.
  Duration backoffFor(int attempts) {
    final growth = math
        .pow(backoffMultiplier, math.max(attempts, 0))
        .toDouble();
    final millis = (initialBackoff.inMilliseconds * growth).round();
    final capped = math.min(millis, maxBackoff.inMilliseconds);
    return Duration(milliseconds: capped);
  }

  /// Whether [attempts] failed tries exceed the patience limit, i.e. the
  /// mutation should be surfaced as failed.
  bool isExhausted(int attempts) => attempts >= maxAttempts;
}
