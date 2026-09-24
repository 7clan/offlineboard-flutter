import '../../domain/entities/sync_enums.dart';

/// Wire DTOs of the OfflineBoard sync protocol.
///
/// Both sides of the simulated link use these: the [SyncApiClient] builds /
/// parses them, and the in-process `MockSyncServer` answers them. Keeping
/// the wire format in one file makes the contract reviewable in one place.

/// One queued mutation as pushed to `POST /sync/push`.
class PushMutation {
  /// Creates a wire mutation.
  const PushMutation({
    required this.mutationId,
    required this.type,
    required this.entityType,
    required this.entityId,
    required this.payload,
    required this.baseUpdatedAt,
    required this.baseVersion,
    required this.clientTimestamp,
  });

  /// Client-generated idempotency key — the server remembers it, replays
  /// are answered `applied` without re-applying.
  final String mutationId;

  /// `create` / `update` / `delete`.
  final MutationType type;

  /// `project` / `task`.
  final EntityType entityType;

  /// Affected record id.
  final String entityId;

  /// Full new record state (the tombstone row for deletes).
  final Map<String, dynamic> payload;

  /// `updatedAt` the local edit was applied on top of.
  final int baseUpdatedAt;

  /// `version` the local edit was applied on top of — the value the server
  /// must still be at for a clean apply.
  final int baseVersion;

  /// When the local edit happened (UTC millis).
  final int clientTimestamp;

  /// Serializes to the request JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'mutationId': mutationId,
    'type': type.name,
    'entityType': entityType.name,
    'entityId': entityId,
    'payload': payload,
    'baseUpdatedAt': baseUpdatedAt,
    'baseVersion': baseVersion,
    'clientTimestamp': clientTimestamp,
  };
}

/// Per-item push outcome.
enum PushItemStatus {
  /// The server applied the mutation (or it was an idempotent replay).
  applied,

  /// Base version mismatch — the server returned its current record and
  /// the client must resolve the conflict.
  conflict,

  /// The payload is invalid (e.g. empty title); retrying unchanged will
  /// fail again.
  rejected,
}

/// One entry of the `results` array in a push response.
class PushResultItem {
  /// Creates a result item.
  const PushResultItem({
    required this.mutationId,
    required this.status,
    this.record,
    this.reason,
  });

  /// Echoed mutation id — how the engine matches results back to queue
  /// entries.
  final String mutationId;

  /// Outcome for this mutation.
  final PushItemStatus status;

  /// The server's current record — present on conflicts, the input of the
  /// `ConflictResolver`.
  final Map<String, dynamic>? record;

  /// Human-readable detail (e.g. why a mutation was rejected).
  final String? reason;

  /// Parses one result entry. Throws [FormatException] on a malformed
  /// entry so the client can surface `MalformedResponseException`.
  factory PushResultItem.fromJson(Map<String, dynamic> json) {
    final mutationId = json['mutationId'];
    final statusName = json['status'];
    if (mutationId is! String || statusName is! String) {
      throw const FormatException('Push result is missing mutationId/status.');
    }
    final status = switch (statusName) {
      'applied' => PushItemStatus.applied,
      'conflict' => PushItemStatus.conflict,
      'rejected' => PushItemStatus.rejected,
      _ => throw FormatException('Unknown push result status: $statusName'),
    };
    final record = json['record'];
    final reason = json['reason'];
    return PushResultItem(
      mutationId: mutationId,
      status: status,
      record: record is Map<String, dynamic> ? record : null,
      reason: reason is String ? reason : null,
    );
  }
}

/// Parsed `GET /sync/pull` response.
class PullResponse {
  /// Creates a pull response.
  const PullResponse({
    required this.projects,
    required this.tasks,
    required this.serverTimeMillis,
  });

  /// Changed project records (tombstones included).
  final List<Map<String, dynamic>> projects;

  /// Changed task records (tombstones included).
  final List<Map<String, dynamic>> tasks;

  /// The server clock at response time — the next `since` cursor.
  final int serverTimeMillis;

  /// Parses a pull response body. Throws [FormatException] on malformed
  /// shapes.
  factory PullResponse.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Pull response is missing "data".');
    }
    final serverTime = data['serverTime'];
    if (serverTime is! num) {
      throw const FormatException('Pull response is missing "serverTime".');
    }
    final rawProjects = data['projects'];
    final rawTasks = data['tasks'];
    if (rawProjects is! List || rawTasks is! List) {
      throw const FormatException('Pull response is missing record lists.');
    }
    return PullResponse(
      projects: [
        for (final item in rawProjects)
          if (item is Map<String, dynamic>) item,
      ],
      tasks: [
        for (final item in rawTasks)
          if (item is Map<String, dynamic>) item,
      ],
      serverTimeMillis: serverTime.toInt(),
    );
  }
}
