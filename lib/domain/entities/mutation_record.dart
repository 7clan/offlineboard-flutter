import 'dart:convert';

import 'sync_enums.dart';

/// One entry of the durable sync queue (a queued local mutation).
///
/// The queue lives in the `pending_mutations` SQLite table and survives app
/// restarts — it IS the offline capability. `mutationId` is the client-side
/// idempotency key: the server remembers it, so duplicate pushes are
/// recognized and answered "applied" without re-applying.
class MutationRecord {
  /// Creates a queue entry.
  const MutationRecord({
    required this.mutationId,
    required this.type,
    required this.entityType,
    required this.entityId,
    required this.payloadJson,
    required this.baseUpdatedAt,
    required this.baseVersion,
    required this.clientTimestamp,
    required this.queuedAt,
    this.attempts = 0,
    this.lastError,
  });

  /// Client-generated unique id — the idempotency key on the server.
  final String mutationId;

  /// Whether this mutation creates, updates or deletes the record.
  final MutationType type;

  /// Whether the record is a project or a task.
  final EntityType entityType;

  /// Id of the affected record.
  final String entityId;

  /// Full new record state as JSON text (the tombstone row for deletes).
  final String payloadJson;

  /// The `updatedAt` the local edit was applied on top of.
  final int baseUpdatedAt;

  /// The `version` the local edit was applied on top of — the value the
  /// server must still be at for a clean apply.
  final int baseVersion;

  /// When the local edit happened (UTC millis) — the LWW comparison key.
  final int clientTimestamp;

  /// When the mutation entered the queue (UTC millis) — push order.
  final int queuedAt;

  /// Failed push attempts so far.
  final int attempts;

  /// Last failure reason, for diagnostics.
  final String? lastError;

  /// Decoded [payloadJson]. Decoding is safe by construction (the payload
  /// is produced from an entity's `toJson`), but a hand-corrupted row
  /// results in a cast error callers may map.
  Map<String, dynamic> get payload =>
      (jsonDecode(payloadJson) as Map<String, dynamic>).cast<String, dynamic>();

  /// Returns a copy with attempt bookkeeping replaced.
  MutationRecord copyWith({int? attempts, String? lastError}) {
    return MutationRecord(
      mutationId: mutationId,
      type: type,
      entityType: entityType,
      entityId: entityId,
      payloadJson: payloadJson,
      baseUpdatedAt: baseUpdatedAt,
      baseVersion: baseVersion,
      clientTimestamp: clientTimestamp,
      queuedAt: queuedAt,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
    );
  }

  @override
  String toString() =>
      'MutationRecord($mutationId, ${type.name} ${entityType.name} '
      '$entityId, attempts: $attempts)';
}
