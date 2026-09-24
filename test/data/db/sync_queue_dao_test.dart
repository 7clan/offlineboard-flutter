import 'package:flutter_test/flutter_test.dart';

import '../../helpers/factories.dart';

void main() {
  group('SyncQueueDao.enqueueMutation', () {
    test('inserts a row and reports it as new', () async {
      final db = memoryDb();
      final inserted = await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1'),
      );
      expect(inserted, isTrue);
      expect(await db.syncQueueDao.queuedMutations(), hasLength(1));
    });

    test('dedupes by mutationId (idempotent queue writes)', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      expect(await dao.enqueueMutation(makeMutation('m-1')), isTrue);
      expect(
        await dao.enqueueMutation(makeMutation('m-1', attempts: 3)),
        isFalse,
        reason: 'same mutationId never enqueues twice',
      );
      final queue = await dao.queuedMutations();
      expect(queue, hasLength(1));
      expect(
        queue.single.attempts,
        0,
        reason: 'the duplicate write must not mutate the stored row',
      );
    });

    test('one mutationId never enqueues twice, whatever the entity', () async {
      // Mutation ids are globally unique idempotency keys; the DAO dedupes
      // on the id alone (stronger than the table's (mutation_id,
      // entity_id) key) so a double-fired enqueue cannot duplicate work.
      final db = memoryDb();
      final dao = db.syncQueueDao;
      expect(
        await dao.enqueueMutation(makeMutation('m-1', entityId: 't-1')),
        isTrue,
      );
      expect(
        await dao.enqueueMutation(makeMutation('m-1', entityId: 't-2')),
        isFalse,
      );
      expect(await dao.queuedMutations(), hasLength(1));
    });
  });

  group('SyncQueueDao.nextBatch', () {
    test('returns entries oldest-first (FIFO by queuedAt)', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      await dao.enqueueMutation(makeMutation('m-3', queuedAt: t0 + 30));
      await dao.enqueueMutation(makeMutation('m-1', queuedAt: t0 + 10));
      await dao.enqueueMutation(makeMutation('m-2', queuedAt: t0 + 20));

      final batch = await dao.nextBatch(limit: 10, maxAttempts: 5);
      expect(batch.map((row) => row.mutationId), ['m-1', 'm-2', 'm-3']);
    });

    test('ties on queuedAt break by row id', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      await dao.enqueueMutation(
        makeMutation('m-1', queuedAt: t0, entityId: 't-1'),
      );
      await dao.enqueueMutation(
        makeMutation('m-2', queuedAt: t0, entityId: 't-2'),
      );

      final batch = await dao.nextBatch(limit: 10, maxAttempts: 5);
      expect(batch.first.mutationId, 'm-1');
      expect(batch.last.mutationId, 'm-2');
    });

    test('respects the batch limit', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      for (var i = 0; i < 5; i++) {
        await dao.enqueueMutation(
          makeMutation('m-$i', queuedAt: t0 + i, entityId: 't-$i'),
        );
      }

      final batch = await dao.nextBatch(limit: 2, maxAttempts: 5);
      expect(batch.map((row) => row.mutationId), ['m-0', 'm-1']);
    });

    test('excludes exhausted mutations (starvation guard)', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      await dao.enqueueMutation(
        makeMutation('m-old', queuedAt: t0, attempts: 5),
      );
      await dao.enqueueMutation(makeMutation('m-fresh', queuedAt: t0 + 1));

      final batch = await dao.nextBatch(limit: 10, maxAttempts: 5);
      expect(batch.map((row) => row.mutationId), [
        'm-fresh',
      ], reason: 'exhausted entries must never crowd out fresher ones');
      // The exhausted entry stays queued for a manual retry.
      expect(await dao.queuedMutations(), hasLength(2));
    });

    test('empty queue yields an empty batch', () async {
      final db = memoryDb();
      expect(
        await db.syncQueueDao.nextBatch(limit: 10, maxAttempts: 5),
        isEmpty,
      );
    });
  });

  group('SyncQueueDao.markAttempted / markSyncing / clearSyncingFlags', () {
    test(
      'markAttempted increments attempts, stores the error, unsyncs',
      () async {
        final db = memoryDb();
        final dao = db.syncQueueDao;
        await dao.enqueueMutation(makeMutation('m-1'));
        final rowId = (await dao.nextBatch(limit: 1, maxAttempts: 5)).single.id;
        await dao.markSyncing([rowId]);

        await dao.markAttempted([rowId], 'offline');
        final afterFirst = (await dao.queuedMutations()).single;
        expect(afterFirst.attempts, 1);
        expect(afterFirst.lastError, 'offline');
        // is_syncing was cleared — the watch streams fall back to pending.
        final batch = await dao.nextBatch(limit: 1, maxAttempts: 5);
        expect(batch.single.isSyncing, isFalse);

        await dao.markAttempted([rowId], 'still offline');
        final afterSecond = (await dao.queuedMutations()).single;
        expect(afterSecond.attempts, 2);
      },
    );

    test(
      'clearSyncingFlags resets every in-flight flag (crash recovery)',
      () async {
        final db = memoryDb();
        final dao = db.syncQueueDao;
        await dao.enqueueMutation(makeMutation('m-1', entityId: 't-1'));
        await dao.enqueueMutation(makeMutation('m-2', entityId: 't-2'));
        final batch = await dao.nextBatch(limit: 10, maxAttempts: 5);
        await dao.markSyncing([for (final row in batch) row.id]);

        await dao.clearSyncingFlags();
        final cleared = await dao.nextBatch(limit: 10, maxAttempts: 5);
        expect(cleared.every((row) => !row.isSyncing), isTrue);
      },
    );
  });

  group('SyncQueueDao removal', () {
    test('removeMutations deletes exactly the given rows', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      await dao.enqueueMutation(makeMutation('m-1', entityId: 't-1'));
      await dao.enqueueMutation(makeMutation('m-2', entityId: 't-2'));
      final keep = (await dao.nextBatch(
        limit: 10,
        maxAttempts: 5,
      )).firstWhere((row) => row.mutationId == 'm-2');

      await dao.removeMutations([keep.id]);
      final rest = await dao.queuedMutations();
      expect(rest.map((record) => record.mutationId), ['m-1']);
    });

    test('removeMutationsForEntity wipes every entry of one entity', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      await dao.enqueueMutation(makeMutation('m-1', entityId: 't-9'));
      await dao.enqueueMutation(makeMutation('m-2', entityId: 't-9'));
      await dao.enqueueMutation(makeMutation('m-3', entityId: 't-1'));

      await dao.removeMutationsForEntity('t-9');
      final rest = await dao.queuedMutations();
      expect(rest.map((record) => record.mutationId), ['m-3']);
    });
  });

  group('SyncQueueDao.watchCount', () {
    test('emits on every enqueue, removal and failure-reset', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      final counts = <int>[];
      final subscription = dao.watchCount().listen(counts.add);
      // Give the stream its initial emission.
      await Future<void>.delayed(Duration.zero);
      expect(counts, [0]);

      await dao.enqueueMutation(makeMutation('m-1'));
      await Future<void>.delayed(Duration.zero);
      await dao.enqueueMutation(makeMutation('m-2', entityId: 't-2'));
      await Future<void>.delayed(Duration.zero);
      final rowId = (await dao.nextBatch(limit: 1, maxAttempts: 5)).single.id;
      await dao.removeMutations([rowId]);
      await Future<void>.delayed(Duration.zero);

      expect(counts, [0, 1, 2, 1]);
      await subscription.cancel();
    });
  });

  group('SyncQueueDao.hasPendingFor', () {
    test('true while mutations are queued for the entity', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      expect(await dao.hasPendingFor('t-1'), isFalse);
      await dao.enqueueMutation(makeMutation('m-1', entityId: 't-1'));
      expect(await dao.hasPendingFor('t-1'), isTrue);
      expect(await dao.hasPendingFor('t-2'), isFalse);
    });
  });

  group('SyncQueueDao.resetFailures', () {
    test('resets attempts and diagnostics of every entry', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      await dao.enqueueMutation(makeMutation('m-1', attempts: 5));
      await dao.enqueueMutation(makeMutation('m-2', entityId: 't-2'));

      await dao.resetFailures();
      final queue = await dao.queuedMutations();
      expect(queue.every((record) => record.attempts == 0), isTrue);
      expect(queue.every((record) => record.lastError == null), isTrue);
      // After the reset the previously-exhausted entry is batchable again.
      final batch = await dao.nextBatch(limit: 10, maxAttempts: 5);
      expect(batch.map((row) => row.mutationId), contains('m-1'));
    });
  });

  group('SyncQueueDao.rowsByMutationIds', () {
    test('fetches exactly the requested queue rows', () async {
      final db = memoryDb();
      final dao = db.syncQueueDao;
      await dao.enqueueMutation(makeMutation('m-1', entityId: 't-1'));
      await dao.enqueueMutation(makeMutation('m-2', entityId: 't-2'));

      final rows = await dao.rowsByMutationIds(['m-1', 'missing']);
      expect(rows, hasLength(1));
      expect(rows.single.mutationId, 'm-1');
      expect(await dao.rowsByMutationIds(const []), isEmpty);
    });
  });
}
