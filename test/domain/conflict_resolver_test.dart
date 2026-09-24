import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/data/sync/conflict_resolver.dart';
import 'package:offlineboard/domain/entities/conflict_resolution.dart';
import 'package:offlineboard/domain/entities/mutation_record.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';

/// Exhaustive unit matrix for the last-write-wins resolver — pure inputs,
/// no clock, no database, no network.
void main() {
  const resolver = LastWriteWinsConflictResolver();

  MutationRecord mutation({
    required String mutationId,
    required int clientTimestamp,
    MutationType type = MutationType.update,
    String entityId = 'p-1',
  }) {
    return MutationRecord(
      mutationId: mutationId,
      type: type,
      entityType: EntityType.project,
      entityId: entityId,
      payloadJson: '{}',
      baseUpdatedAt: 0,
      baseVersion: 1,
      clientTimestamp: clientTimestamp,
      queuedAt: clientTimestamp,
    );
  }

  ServerRecordSnapshot server({
    required int updatedAt,
    required int version,
    String? lastMutationId,
    bool isDeleted = false,
  }) {
    return ServerRecordSnapshot(
      entityType: EntityType.project,
      entityId: 'p-1',
      updatedAt: updatedAt,
      version: version,
      isDeleted: isDeleted,
      payload: <String, dynamic>{'id': 'p-1'},
      lastMutationId: lastMutationId,
    );
  }

  group('timestamp comparison — the newer write wins', () {
    test('local mutation newer than the server record → local wins', () {
      final verdict = resolver.resolve(
        mutation: mutation(mutationId: 'm-local', clientTimestamp: 2000),
        serverRecord: server(updatedAt: 1000, version: 3),
      );
      expect(verdict, ConflictResolution.localWins);
    });

    test('server record newer than the local mutation → server wins', () {
      final verdict = resolver.resolve(
        mutation: mutation(mutationId: 'm-local', clientTimestamp: 1000),
        serverRecord: server(updatedAt: 2000, version: 3),
      );
      expect(verdict, ConflictResolution.serverWins);
    });
  });

  group('delete tombstones beat older updates', () {
    test('local delete newer than the server update → local (delete) wins', () {
      final verdict = resolver.resolve(
        mutation: mutation(
          mutationId: 'm-delete',
          clientTimestamp: 5000,
          type: MutationType.delete,
        ),
        serverRecord: server(updatedAt: 1000, version: 3),
      );
      expect(verdict, ConflictResolution.localWins);
    });

    test('server tombstone newer than the local edit → server wins', () {
      final verdict = resolver.resolve(
        mutation: mutation(mutationId: 'm-edit', clientTimestamp: 1000),
        serverRecord: server(
          updatedAt: 5000,
          version: 3,
          isDeleted: true,
          lastMutationId: 'm-server-delete',
        ),
      );
      expect(verdict, ConflictResolution.serverWins);
    });

    test('older local delete loses to a newer server update', () {
      final verdict = resolver.resolve(
        mutation: mutation(
          mutationId: 'm-delete',
          clientTimestamp: 1000,
          type: MutationType.delete,
        ),
        serverRecord: server(
          updatedAt: 5000,
          version: 3,
          lastMutationId: 'm-server-edit',
        ),
      );
      expect(verdict, ConflictResolution.serverWins);
    });
  });

  group('exact timestamp tie → deterministic id tiebreak', () {
    test('smaller mutation id wins against a known server write id', () {
      // 'a-local' < 'z-server' → local wins.
      expect(
        resolver.resolve(
          mutation: mutation(mutationId: 'a-local', clientTimestamp: 1000),
          serverRecord: server(
            updatedAt: 1000,
            version: 3,
            lastMutationId: 'z-server',
          ),
        ),
        ConflictResolution.localWins,
      );
      // 'z-local' > 'a-server' → server wins.
      expect(
        resolver.resolve(
          mutation: mutation(mutationId: 'z-local', clientTimestamp: 1000),
          serverRecord: server(
            updatedAt: 1000,
            version: 3,
            lastMutationId: 'a-server',
          ),
        ),
        ConflictResolution.serverWins,
      );
    });

    test('seeded server record (no last mutation id) → local wins', () {
      final verdict = resolver.resolve(
        mutation: mutation(mutationId: 'z-local', clientTimestamp: 1000),
        serverRecord: server(updatedAt: 1000, version: 1),
      );
      expect(verdict, ConflictResolution.localWins);
    });

    test('identical inputs resolve the same way on every device', () {
      // The tiebreak is pure string comparison — no randomness, no clock,
      // so two devices fed the same pair pick the same winner.
      for (var i = 0; i < 25; i++) {
        expect(
          resolver.resolve(
            mutation: mutation(mutationId: 'm-0', clientTimestamp: 42),
            serverRecord: server(
              updatedAt: 42,
              version: 7,
              lastMutationId: 'm-1',
            ),
          ),
          ConflictResolution.localWins,
        );
      }
    });
  });

  group('resolver is stateless and side-effect free', () {
    test('repeated resolutions with equal inputs agree', () {
      final input = mutation(mutationId: 'm-x', clientTimestamp: 9);
      final snap = server(updatedAt: 10, version: 2);
      final first = resolver.resolve(mutation: input, serverRecord: snap);
      for (var i = 0; i < 10; i++) {
        expect(resolver.resolve(mutation: input, serverRecord: snap), first);
      }
    });
  });
}
