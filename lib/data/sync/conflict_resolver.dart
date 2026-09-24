import '../../domain/entities/conflict_resolution.dart';
import '../../domain/entities/mutation_record.dart';
import '../../domain/sync/conflict_resolver.dart';

/// Version-vector-free LAST-WRITE-WINS resolver.
///
/// Rules (see `docs/OFFLINE_SYNC.md`):
///
/// 1. **Timestamp comparison.** The local mutation's `clientTimestamp`
///    plays against the server record's `updatedAt` — the newer write
///    wins. This covers every shape naturally:
///    * a local *delete* newer than the server's last update wins
///      (delete beats update),
///    * a server *tombstone* newer than the local edit wins (the server
///      delete stands),
///    * otherwise the plain newer content wins.
/// 2. **Deterministic tiebreak.** On an exact timestamp tie the two
///    competing *write* identifiers are compared lexicographically
///    (smaller id wins). When the server record was seeded (no known
///    last-mutation id), the local mutation wins — no coin flips, every
///    device resolves identically.
///
/// The class is pure: no database, clock or network access, which makes
/// the conflict matrix exhaustively unit-testable.
class LastWriteWinsConflictResolver implements ConflictResolver {
  /// Creates the resolver (stateless — one shared instance is fine).
  const LastWriteWinsConflictResolver();

  @override
  ConflictResolution resolve({
    required MutationRecord mutation,
    required ServerRecordSnapshot serverRecord,
  }) {
    if (mutation.clientTimestamp != serverRecord.updatedAt) {
      return mutation.clientTimestamp > serverRecord.updatedAt
          ? ConflictResolution.localWins
          : ConflictResolution.serverWins;
    }

    // Exact timestamp tie → compare the writes' ids, smaller wins.
    final serverWriteId = serverRecord.lastMutationId;
    if (serverWriteId == null) return ConflictResolution.localWins;
    return mutation.mutationId.compareTo(serverWriteId) < 0
        ? ConflictResolution.localWins
        : ConflictResolution.serverWins;
  }
}
