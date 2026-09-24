import 'sync_enums.dart';

/// Outcome of a resolved push conflict — which side won.
enum ConflictResolution {
  /// The local mutation won: its content stays/applies locally and is
  /// re-pushed with a corrected base version.
  localWins,

  /// The server record won: it is applied locally and the queued mutation is
  /// dropped.
  serverWins,
}

/// Immutable snapshot of a server record as returned with a CONFLICT push
/// result — the other party of a [ConflictResolver] decision.
class ServerRecordSnapshot {
  /// Creates a snapshot.
  const ServerRecordSnapshot({
    required this.entityType,
    required this.entityId,
    required this.updatedAt,
    required this.version,
    required this.isDeleted,
    required this.payload,
    this.lastMutationId,
  });

  /// Entity kind of the record.
  final EntityType entityType;

  /// Id of the record.
  final String entityId;

  /// Server-side `updatedAt` (UTC millis) — the LWW comparison key.
  final int updatedAt;

  /// Server-side `version`.
  final int version;

  /// Whether the server already deleted the record (tombstone).
  final bool isDeleted;

  /// Full server record (the winner's content when the server wins).
  final Map<String, dynamic> payload;

  /// Mutation id of the last write the server accepted for this record.
  ///
  /// Used as the deterministic tiebreak when timestamps are exactly equal.
  final String? lastMutationId;

  /// Parses a conflict `record` from the wire.
  ///
  /// [entityType] comes from the mutation being pushed (client and server
  /// agree on it by construction). Throws [FormatException] when required
  /// fields are missing — transport code maps that to a
  /// `MalformedResponseException`.
  factory ServerRecordSnapshot.parse({
    required EntityType entityType,
    required Map<String, dynamic> json,
  }) {
    final id = json['id'];
    final updatedAt = json['updatedAt'];
    final version = json['version'];
    if (id is! String || updatedAt is! num || version is! num) {
      throw const FormatException('Conflict record is missing id/version.');
    }
    final lastMutationId = json['lastMutationId'];
    return ServerRecordSnapshot(
      entityType: entityType,
      entityId: id,
      updatedAt: updatedAt.toInt(),
      version: version.toInt(),
      isDeleted: json['isDeleted'] == true,
      payload: json,
      lastMutationId: lastMutationId is String ? lastMutationId : null,
    );
  }
}
