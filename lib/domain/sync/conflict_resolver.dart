import '../entities/conflict_resolution.dart';
import '../entities/mutation_record.dart';

/// Pure contract for resolving push conflicts.
///
/// Strategy (version-vector-free LAST-WRITE-WINS, see `docs/OFFLINE_SYNC.md`):
///
/// 1. Compare the local mutation's `clientTimestamp` with the server
///    record's `updatedAt` — the newer write wins. A local `delete` that is
///    newer than the server's last update therefore wins (delete beats
///    update); a server tombstone newer than the local edit wins too.
/// 2. Tiebreak when the timestamps are *exactly* equal: the write ids
///    (`mutationId` of each competing write) are compared lexicographically —
///    deterministic on every device, no coin flips.
///
/// Implementations must stay pure (no database, no clock, no I/O) so the
/// resolution rules are exhaustively unit-testable.
abstract interface class ConflictResolver {
  /// Decides which side wins when the server answered CONFLICT for
  /// [mutation] and reported [serverRecord] as its current state.
  ConflictResolution resolve({
    required MutationRecord mutation,
    required ServerRecordSnapshot serverRecord,
  });
}
