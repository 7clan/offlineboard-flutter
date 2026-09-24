/// Sync-related enums shared across every layer.
///
/// Stored as indexes (fast filtering in SQL) and serialized by name on the
/// wire (robust to reordering) — the mappers own both conversions.
library;

/// Per-record sync status surfaced in the UI (badge next to every project
/// and task).
///
/// Derivation rule (see `TasksDao`/`ProjectsDao`):
/// * `failed`   — a queued mutation for the record exhausted its attempts,
/// * `syncing`  — a queued mutation is currently being pushed,
/// * `pending`  — a queued mutation exists (not yet pushed / retrying),
/// * `synced`   — nothing queued for the record.
enum SyncStatus {
  /// Local state == server state.
  synced,

  /// A mutation is queued but has not been pushed yet.
  pending,

  /// The sync engine is pushing a mutation for this record right now.
  syncing,

  /// The mutation failed more times than the retry policy allows; it stays
  /// in the queue until manually retried.
  failed,
}

/// Kind of local mutation captured in the durable sync queue.
enum MutationType {
  /// Record created locally.
  create,

  /// Record modified locally.
  update,

  /// Record deleted locally (tombstone).
  delete,
}

/// Entity kind a mutation refers to.
enum EntityType {
  /// A project record.
  project,

  /// A task record.
  task,
}
