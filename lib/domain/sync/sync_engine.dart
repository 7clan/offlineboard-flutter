import '../entities/mutation_record.dart';

/// Result of one full push round (a single `POST /sync/push`).
class SyncOutcome {
  /// Creates an outcome.
  const SyncOutcome({
    this.mutationsSent = 0,
    this.applied = 0,
    this.conflictsResolved = 0,
    this.rejected = 0,
    this.failed = 0,
    this.retryAfter,
    this.error,
  });

  /// Queue entries included in the push batch.
  final int mutationsSent;

  /// Mutations the server applied (including idempotent replays).
  final int applied;

  /// Conflicts resolved via the `ConflictResolver`.
  final int conflictsResolved;

  /// Mutations permanently rejected by the server (bad payload).
  final int rejected;

  /// Mutations that failed again this round (transport / server error).
  final int failed;

  /// When non-null, wait this long before the next automatic attempt
  /// (exponential backoff; `null` means nothing left to retry).
  final Duration? retryAfter;

  /// The mapped transport error, when the whole batch failed.
  final Object? error;

  /// Outcome when there was nothing to do.
  static const SyncOutcome empty = SyncOutcome();

  /// Whether the round ended with unresolved trouble worth surfacing.
  bool get hasFailures => failed > 0 || rejected > 0 || error != null;

  @override
  String toString() =>
      'SyncOutcome(sent: $mutationsSent, applied: $applied, '
      'conflicts: $conflictsResolved, rejected: $rejected, '
      'failed: $failed, retryAfter: $retryAfter)';
}

/// Result of one pull round (`GET /sync/pull`).
class PullOutcome {
  /// Creates an outcome.
  const PullOutcome({
    this.projectsApplied = 0,
    this.tasksApplied = 0,
    this.skipped = 0,
    this.serverTimeMillis = 0,
  });

  /// Server project records applied locally (LWW guard honoured).
  final int projectsApplied;

  /// Server task records applied locally (LWW guard honoured).
  final int tasksApplied;

  /// Server records skipped because local edits are pending for them
  /// (never overwrite pending local edits) or local is newer.
  final int skipped;

  /// The server's clock at response time — persisted as the next
  /// `since` cursor.
  final int serverTimeMillis;

  @override
  String toString() =>
      'PullOutcome(projects: $projectsApplied, tasks: $tasksApplied, '
      'skipped: $skipped, serverTime: $serverTimeMillis)';
}

/// Contract of the offline-first sync engine.
///
/// The engine drains the durable queue to the server (push) and applies
/// server-side changes locally (pull), resolving conflicts with the
/// injected `ConflictResolver`. It is deliberately *connectivity-free*:
/// whether the device is online is decided by the app layer
/// (`ConnectivityService` + `SyncController`), which also owns timers. The
/// engine only reports what happened and when a retry would be sensible
/// ([SyncOutcome.retryAfter]).
abstract interface class SyncEngine {
  /// Convenience: [pushPending] followed by [pullSince].
  ///
  /// Pushing first guarantees local wins get to the server before the
  /// local rows are compared against a pull.
  Future<SyncOutcome> syncNow();

  /// Pushes the next queue batch (ordered by `queuedAt`), then handles each
  /// per-mutation result:
  ///
  /// * `applied`  — dequeue (the local row already matches by design),
  /// * `conflict` — resolve via the `ConflictResolver`; the winner is
  ///   applied locally and the mutation is resolved off the queue,
  /// * `rejected` — counts as an attempt; retries per the backoff policy,
  ///   surfaces as failed after the max attempts,
  /// * transport failure — the whole batch is marked attempted and a
  ///   [SyncOutcome.retryAfter] backoff is reported.
  Future<SyncOutcome> pushPending();

  /// Pulls server records changed since the last pull and applies them
  /// locally with a last-write-wins guard: server content wins when it is
  /// newer AND the local record has no queued mutations (pending local
  /// edits are never overwritten).
  Future<PullOutcome> pullSince();

  /// Resets the failure bookkeeping of exhausted mutations (attempts,
  /// lastError) and immediately pushes them again — the manual "retry"
  /// button.
  Future<SyncOutcome> retryFailed();

  /// Number of mutations currently in the queue (pending + failed).
  Future<int> queuedMutationCount();

  /// The queue entries as domain records, newest last — for diagnostics
  /// and the sync debug screen.
  Future<List<MutationRecord>> queuedMutations();
}
