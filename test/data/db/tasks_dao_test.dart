import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/data/db/app_database.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/domain/entities/task_filter.dart';

import '../../helpers/factories.dart';

void main() {
  const maxAttempts = 5;

  /// Seeds a small dataset spanning every filter dimension.
  Future<void> seed(AppDatabase db) async {
    await db.projectsDao.upsertProject(makeProject('p-1'));
    await db.projectsDao.upsertProject(makeProject('p-2'));
    await db.tasksDao.upsertTask(
      makeTask('t-1', title: 'Buy groceries', priority: TaskPriority.medium),
    );
    await db.tasksDao.upsertTask(
      makeTask(
        't-2',
        projectId: 'p-2',
        title: 'Prepare quarterly review',
        priority: TaskPriority.urgent,
        dueDate: t0 + 86400000,
      ),
    );
    await db.tasksDao.upsertTask(
      makeTask(
        't-3',
        title: 'Water the plants',
        priority: TaskPriority.low,
        isCompleted: true,
      ),
    );
    await db.tasksDao.upsertTask(
      makeTask('t-4', title: 'Book dentist', priority: TaskPriority.high),
    );
    await db.tasksDao.upsertTask(
      makeTask('t-5', title: 'Plan offsite', isDeleted: true),
    );
  }

  test('upsertTask inserts and updates rows by id', () async {
    final db = memoryDb();
    await db.projectsDao.upsertProject(makeProject('p-1'));
    final dao = db.tasksDao;
    await dao.upsertTask(makeTask('t-1', title: 'v1', version: 1));
    await dao.upsertTask(
      makeTask('t-1', title: 'v2', version: 2, updatedAt: t0 + 1000),
    );

    final loaded = await dao.getTaskById('t-1');
    expect(loaded!.title, 'v2');
    expect(loaded.version, 2);
    expect(loaded.updatedAt, t0 + 1000);
    final raw = await db.customSelect('SELECT * FROM tasks').get();
    expect(raw, hasLength(1));
  });

  group('TasksDao.watchTasks filtering', () {
    test('all: non-deleted tasks of every project', () async {
      final db = memoryDb();
      await seed(db);
      final tasks = await db.tasksDao
          .watchTasks(TaskFilter.all, maxAttempts: maxAttempts)
          .first;
      expect(tasks.map((t) => t.id), hasLength(4));
      expect(
        tasks.any((t) => t.id == 't-5'),
        isFalse,
        reason: 'tombstone excluded',
      );
    });

    test('by project', () async {
      final db = memoryDb();
      await seed(db);
      final tasks = await db.tasksDao
          .watchTasks(
            const TaskFilter(projectId: 'p-2'),
            maxAttempts: maxAttempts,
          )
          .first;
      expect(tasks.map((t) => t.id), ['t-2']);
    });

    test('by completion', () async {
      final db = memoryDb();
      await seed(db);
      final completed = await db.tasksDao
          .watchTasks(
            const TaskFilter(completion: TaskCompletionFilter.completed),
            maxAttempts: maxAttempts,
          )
          .first;
      expect(completed.map((t) => t.id), ['t-3']);

      final incomplete = await db.tasksDao
          .watchTasks(
            const TaskFilter(completion: TaskCompletionFilter.incomplete),
            maxAttempts: maxAttempts,
          )
          .first;
      expect(incomplete.map((t) => t.id), isNot(contains('t-3')));
      expect(incomplete, hasLength(3));
    });

    test('by priority', () async {
      final db = memoryDb();
      await seed(db);
      final urgent = await db.tasksDao
          .watchTasks(
            const TaskFilter(priority: TaskPriority.urgent),
            maxAttempts: maxAttempts,
          )
          .first;
      expect(urgent.map((t) => t.id), ['t-2']);
    });

    test('by dueBefore (only dated tasks, null due dates excluded)', () async {
      final db = memoryDb();
      await seed(db);
      final dated = await db.tasksDao
          .watchTasks(
            TaskFilter(dueBefore: t0 + 86400000 * 2),
            maxAttempts: maxAttempts,
          )
          .first;
      expect(dated.map((t) => t.id), ['t-2']);
    });

    test('by search — case-insensitive substring on the title', () async {
      final db = memoryDb();
      await seed(db);
      final tasks = await db.tasksDao
          .watchTasks(
            const TaskFilter(search: 'GROCER'),
            maxAttempts: maxAttempts,
          )
          .first;
      expect(tasks.map((t) => t.id), ['t-1']);
    });

    test('combined dimensions intersect', () async {
      final db = memoryDb();
      await seed(db);
      final tasks = await db.tasksDao
          .watchTasks(
            const TaskFilter(
              projectId: 'p-2',
              completion: TaskCompletionFilter.incomplete,
              priority: TaskPriority.urgent,
            ),
            maxAttempts: maxAttempts,
          )
          .first;
      expect(tasks.map((t) => t.id), ['t-2']);
    });

    test('empty search string does not filter', () async {
      final db = memoryDb();
      await seed(db);
      final tasks = await db.tasksDao
          .watchTasks(const TaskFilter(search: '   '), maxAttempts: maxAttempts)
          .first;
      expect(tasks, hasLength(4));
    });
  });

  group('TasksDao.watchTasks ordering', () {
    test(
      'incomplete first, due date ascending, urgent priority first',
      () async {
        final db = memoryDb();
        await db.projectsDao.upsertProject(makeProject('p-1'));
        final dao = db.tasksDao;
        // Completed task with the earliest due date must still sort last.
        await dao.upsertTask(
          makeTask('t-done', dueDate: t0 - 100, isCompleted: true),
        );
        await dao.upsertTask(makeTask('t-later', dueDate: t0 + 5000));
        await dao.upsertTask(makeTask('t-sooner', dueDate: t0 + 1000));
        // Same due date → priority breaks the tie (urgent index 3 > low 0).
        await dao.upsertTask(
          makeTask('t-lowpri', dueDate: t0 + 1000, priority: TaskPriority.low),
        );
        await dao.upsertTask(
          makeTask(
            't-urgentpri',
            dueDate: t0 + 1000,
            priority: TaskPriority.urgent,
          ),
        );
        // No due date at all sorts after dated tasks.
        await dao.upsertTask(makeTask('t-nodue'));

        final tasks = await dao
            .watchTasks(TaskFilter.all, maxAttempts: maxAttempts)
            .first;
        // Among equal due dates priority DESC applies: urgent(3) > medium(1)
        // > low(0) — t-sooner defaults to medium, t-lowpri is low.
        expect(tasks.map((t) => t.id), [
          't-urgentpri',
          't-sooner',
          't-lowpri',
          't-later',
          't-nodue',
          't-done',
        ]);
      },
    );
  });

  group('TasksDao.watchTasks sync status', () {
    test('derives pending from the queue and failed at maxAttempts', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.tasksDao.upsertTask(makeTask('t-1'));
      await db.tasksDao.upsertTask(makeTask('t-2'));
      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityType: EntityType.task, entityId: 't-1'),
      );
      await db.syncQueueDao.enqueueMutation(
        makeMutation(
          'm-2',
          entityType: EntityType.task,
          entityId: 't-2',
          attempts: maxAttempts,
        ),
      );

      final tasks = await db.tasksDao
          .watchTasks(TaskFilter.all, maxAttempts: maxAttempts)
          .first;
      final byId = {for (final task in tasks) task.id: task};
      expect(byId['t-1']!.syncStatus, SyncStatus.pending);
      expect(byId['t-2']!.syncStatus, SyncStatus.failed);
    });
  });

  group('TasksDao single-row and batch reads', () {
    test('watchTask sees tombstones and derives status', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.tasksDao.upsertTask(makeTask('t-1', isDeleted: true));
      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityType: EntityType.task, entityId: 't-1'),
      );

      final watched = await db.tasksDao
          .watchTask('t-1', maxAttempts: maxAttempts)
          .first;
      expect(watched, isNotNull);
      expect(watched!.isDeleted, isTrue);
      expect(watched.syncStatus, SyncStatus.pending);
    });

    test('watchTask emits null for unknown ids', () async {
      final db = memoryDb();
      final watched = await db.tasksDao
          .watchTask('missing', maxAttempts: maxAttempts)
          .first;
      expect(watched, isNull);
    });

    test('getTasksByIds returns a map including tombstones', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.tasksDao.upsertTask(makeTask('t-1'));
      await db.tasksDao.upsertTask(makeTask('t-2', isDeleted: true));

      final map = await db.tasksDao.getTasksByIds(['t-1', 't-2', 'missing']);
      expect(map.keys, containsAll(['t-1', 't-2']));
      expect(map['t-2']!.isDeleted, isTrue);
      expect(map.containsKey('missing'), isFalse);
      expect(await db.tasksDao.getTasksByIds(const []), isEmpty);
    });

    test('watchUnsyncedTasks lists only tasks with queue entries', () async {
      final db = memoryDb();
      await db.projectsDao.upsertProject(makeProject('p-1'));
      await db.tasksDao.upsertTask(makeTask('t-1'));
      await db.tasksDao.upsertTask(makeTask('t-2'));
      await db.tasksDao.upsertTask(makeTask('t-3'));
      await db.syncQueueDao.enqueueMutation(
        makeMutation('m-1', entityType: EntityType.task, entityId: 't-2'),
      );

      final unsynced = await db.tasksDao
          .watchUnsyncedTasks(maxAttempts: maxAttempts)
          .first;
      expect(unsynced.map((t) => t.id), ['t-2']);
    });
  });
}
