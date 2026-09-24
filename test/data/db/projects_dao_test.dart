import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';

import '../../helpers/factories.dart';

void main() {
  const maxAttempts = 5;

  group('ProjectsDao.upsertProject', () {
    test('inserts a new row and reads it back unchanged', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1', name: 'Personal'));

      final loaded = await db.projectsDao.getProjectById('p-1');
      expect(loaded, isNotNull);
      expect(loaded!.id, 'p-1');
      expect(loaded.name, 'Personal');
      expect(loaded.colorValue, 0xFF2E7D32);
      expect(loaded.createdAt, t0);
      expect(loaded.updatedAt, t0);
      expect(loaded.version, 1);
      expect(loaded.isDeleted, isFalse);
    });

    test(
      'upserting the same id replaces the row (bump version/updatedAt)',
      () async {
        final db = memoryDb();
        final dao = db.projectsDao;
        await dao.upsertProject(makeProject('p-1', name: 'v1', version: 1));
        await dao.upsertProject(
          makeProject('p-1', name: 'v2', version: 2, updatedAt: t0 + 5000),
        );

        final loaded = await dao.getProjectById('p-1');
        expect(loaded!.name, 'v2');
        expect(loaded.version, 2);
        expect(loaded.updatedAt, t0 + 5000);
        // Exactly one physical row — upsert, not insert.
        final all = await db.customSelect('SELECT * FROM projects').get();
        expect(all, hasLength(1));
      },
    );

    test('getProjectById returns null for an unknown id', () async {
      final db = memoryDb();
      expect(await db.projectsDao.getProjectById('missing'), isNull);
    });
  });

  group('ProjectsDao.watchProjects', () {
    test('excludes tombstones, orders by name case-insensitively', () async {
      final db = memoryDb();
      final dao = db.projectsDao;
      await dao.upsertProject(makeProject('p-2', name: 'zebra'));
      await dao.upsertProject(makeProject('p-3', name: 'Apple'));
      await dao.upsertProject(makeProject('p-1', name: 'banana'));
      await dao.upsertProject(
        makeProject('p-4', name: 'ghost', isDeleted: true),
      );

      final visible = await dao.watchProjects(maxAttempts: maxAttempts).first;
      expect(visible.map((p) => p.name), ['Apple', 'banana', 'zebra']);
    });

    test('derives synced status when nothing is queued', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));

      final visible = await db.projectsDao
          .watchProjects(maxAttempts: maxAttempts)
          .first;
      expect(visible.single.syncStatus, SyncStatus.synced);
    });

    test('derives pending status when a mutation is queued', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityType: EntityType.project, entityId: 'p-1'),
      );

      final visible = await db.projectsDao
          .watchProjects(maxAttempts: maxAttempts)
          .first;
      expect(visible.single.syncStatus, SyncStatus.pending);
    });

    test('derives syncing status while a queue row is in flight', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityType: EntityType.project, entityId: 'p-1'),
      );
      final batch = await db.syncQueueDao.nextBatch(limit: 10, maxAttempts: 5);
      await db.syncQueueDao.markSyncing([batch.single.id]);

      final visible = await db.projectsDao
          .watchProjects(maxAttempts: maxAttempts)
          .first;
      expect(visible.single.syncStatus, SyncStatus.syncing);
    });

    test('derives failed status once attempts reach maxAttempts', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.syncQueueDao.enqueueMutation(
        makeMutation(
          'm-2',
          entityType: EntityType.project,
          entityId: 'p-1',
          attempts: 5,
        ),
      );

      final visible = await db.projectsDao
          .watchProjects(maxAttempts: maxAttempts)
          .first;
      expect(visible.single.syncStatus, SyncStatus.failed);
    });
  });

  group('ProjectsDao.watchProject (single row)', () {
    test('watches one project including its tombstone', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1', isDeleted: true));

      final watched = await db.projectsDao
          .watchProject('p-1', maxAttempts: maxAttempts)
          .first;
      // Tombstones stay visible on the single-row watch (detail views and
      // conflict resolution rely on it).
      expect(watched, isNotNull);
      expect(watched!.isDeleted, isTrue);
    });

    test('emits null for an unknown id', () async {
      final db = memoryDb();
      final watched = await db.projectsDao
          .watchProject('missing', maxAttempts: maxAttempts)
          .first;
      expect(watched, isNull);
    });

    test(
      'status subquery placeholders bind correctly (maxAttempts before id)',
      () async {
        // Regression guard for the bind-order bug fixed in bf05a2e: the
        // status columns' `attempts >= ?` appears in the SQL before the
        // WHERE `id = ?`, so the variables must be ordered
        // [maxAttempts, id] — a swapped order would compare attempts
        // against a string and break this watch.
        final db = memoryDb();
        await db.projectsDao.upsertProject(makeProject('p-9', name: 'target'));
        await db.projectsDao.upsertProject(makeProject('p-1', name: 'other'));
        await db.syncQueueDao.enqueueMutation(
          makeMutation(
            'm-1',
            entityType: EntityType.project,
            entityId: 'p-9',
            attempts: 4,
          ),
        );

        final watched = await db.projectsDao
            .watchProject('p-9', maxAttempts: maxAttempts)
            .first;
        expect(watched!.name, 'target');
        expect(watched.syncStatus, SyncStatus.pending);

        // Cross-check the OTHER project: it stays synced even though the
        // queue holds a near-exhausted row for p-9.
        final other = await db.projectsDao
            .watchProject('p-1', maxAttempts: maxAttempts)
            .first;
        expect(other!.syncStatus, SyncStatus.synced);
      },
    );
  });

  group('ProjectsDao.getTasksForProject', () {
    test('returns non-deleted children only', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.projectsDao.upsertProject(makeProject('p-2'));
      await db.tasksDao.upsertTask(makeTask('t-1', projectId: 'p-1'));
      await db.tasksDao.upsertTask(makeTask('t-2', projectId: 'p-1'));
      await db.tasksDao.upsertTask(
        makeTask('t-3', projectId: 'p-1', isDeleted: true),
      );
      await db.tasksDao.upsertTask(makeTask('t-4', projectId: 'p-2'));

      final children = await db.projectsDao.getTasksForProject('p-1');
      expect(children.map((t) => t.id), {'t-1', 't-2'});
    });
  });
}
