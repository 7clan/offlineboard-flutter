import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/presentation/providers/database_provider.dart';
import 'package:offlineboard/presentation/providers/queue_badge_provider.dart';

import '../helpers/factories.dart';
import '../helpers/fakes.dart';

// The queue badge is a live count of every queued mutation (pending +
// syncing + failed). It must re-emit on each enqueue and each removal so
// the banner/badge can follow an offline burst and its drain.

Future<void> settle([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'watchCount re-emits on every enqueue and drops back to zero on drain',
    () async {
      final container = stateTestContainer();
      final db = container.read(databaseProvider);
      final emitted = <int>[];
      container.listen(queueBadgeProvider, (_, next) {
        final value = next.value;
        if (value != null) emitted.add(value);
      });

      await settle();
      // Drift's watch streams seed the current value first.
      expect(emitted, [0], reason: 'the initial empty-queue emission');

      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityId: 'e-1'),
      );
      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-2', entityId: 'e-2'),
      );
      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-3', entityId: 'e-3'),
      );
      await settle();
      expect(emitted, [0, 1, 2, 3]);
      expect(container.read(queueBadgeProvider).value, 3);

      // Drain exactly like the engine does after a successful push: take
      // the FIFO batch, then remove those rows.
      final batch = await db.syncQueueDao.nextBatch(limit: 32, maxAttempts: 5);
      expect(batch, hasLength(3));
      await db.syncQueueDao.removeMutations(
        batch.map((row) => row.id).toList(),
      );
      await settle();
      expect(emitted, [0, 1, 2, 3, 0]);
      expect(container.read(queueBadgeProvider).value, 0);
    },
  );

  test(
    'duplicate enqueue of the same mutation does not bump the count',
    () async {
      final container = stateTestContainer();
      final db = container.read(databaseProvider);
      final emitted = <int>[];
      container.listen(queueBadgeProvider, (_, next) {
        final value = next.value;
        if (value != null) emitted.add(value);
      });

      await settle();
      expect(emitted, [0]);

      final insertedFirst = await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityId: 'e-1'),
      );
      final insertedDuplicate = await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityId: 'e-1'),
      );
      expect(insertedFirst, isTrue, reason: 'the first enqueue inserts');
      expect(
        insertedDuplicate,
        isFalse,
        reason: 'UNIQUE (mutation_id, entity_id) makes it a no-op',
      );

      await settle();
      expect(emitted, [0, 1]);
      expect(container.read(queueBadgeProvider).value, 1);
    },
  );
}
