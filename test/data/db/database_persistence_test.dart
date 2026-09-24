import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/data/db/app_database.dart';
import 'package:offlineboard/data/sync/sync_engine_impl.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';

import '../../helpers/factories.dart';

/// Reopen-persistence proof: the queue and the rows live in one SQLite file,
/// so a "restart" (close + reopen on the same path) must preserve every
/// pending mutation, its attempt bookkeeping and the pull cursor — that IS
/// the offline capability.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('offlineboard_test_');
    dbFile = File('${tempDir.path}/app.db');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  AppDatabase open() => AppDatabase(NativeDatabase(dbFile));

  test(
    'rows, queue entries, attempt state and cursor survive a reopen',
    () async {
      final first = open();
      await first.projectsDao.upsertProject(
        makeProject('p-1', name: 'Personal'),
      );
      await first.tasksDao.upsertTask(
        makeTask('t-1', title: 'Buy groceries', priority: TaskPriority.high),
      );
      await first.tasksDao.upsertTask(
        makeTask('t-2', title: 'Done already', isCompleted: true),
      );
      // A create + an update + a delete queued while "offline".
      await first.syncQueueDao.enqueueMutation(
        makeMutation(
          'm-create',
          type: MutationType.create,
          entityType: EntityType.task,
          entityId: 't-1',
        ),
      );
      await first.syncQueueDao.enqueueMutation(
        makeMutation(
          'm-update',
          type: MutationType.update,
          entityType: EntityType.task,
          entityId: 't-2',
          queuedAt: t0 + 10,
        ),
      );
      final deleteRow = makeMutation(
        'm-delete',
        type: MutationType.delete,
        entityType: EntityType.project,
        entityId: 'p-1',
        queuedAt: t0 + 20,
        attempts: 2,
      );
      await first.syncQueueDao.enqueueMutation(deleteRow);
      await first.writeMeta(SyncEngineImpl.lastPullCursorKey, '1735690000000');
      await first.close();

      // "Restart" — a brand new AppDatabase instance on the same file.
      final reopened = open();
      addTearDown(reopened.close);

      final project = await reopened.projectsDao.getProjectById('p-1');
      expect(project!.name, 'Personal');

      final tasks = await reopened.tasksDao.getTasksByIds(['t-1', 't-2']);
      expect(tasks['t-1']!.title, 'Buy groceries');
      expect(tasks['t-1']!.priority, TaskPriority.high);
      expect(tasks['t-2']!.isCompleted, isTrue);

      final queue = await reopened.syncQueueDao.queuedMutations();
      expect(queue.map((record) => record.mutationId), [
        'm-create',
        'm-update',
        'm-delete',
      ], reason: 'FIFO order survives too');
      final delete = queue.singleWhere((r) => r.mutationId == 'm-delete');
      expect(delete.attempts, 2, reason: 'attempt bookkeeping survives');
      expect(delete.type, MutationType.delete);
      expect(delete.entityType, EntityType.project);

      expect(
        await reopened.readMeta(SyncEngineImpl.lastPullCursorKey),
        '1735690000000',
        reason: 'the pull cursor survives — no re-pull of the whole history',
      );

      // The queue is still drainable after the restart.
      final batch = await reopened.syncQueueDao.nextBatch(
        limit: 10,
        maxAttempts: 5,
      );
      expect(batch, hasLength(3));
    },
  );

  test('data written after the reopen is visible on a third open', () async {
    final first = open();
    await first.projectsDao.upsertProject(makeProject('p-1'));
    await first.close();

    final second = open();
    await second.tasksDao.upsertTask(makeTask('t-9', title: 'Added later'));
    await second.syncQueueDao.enqueueMutation(
      makeMutation('m-9', type: MutationType.create, entityId: 't-9'),
    );
    await second.close();

    final third = open();
    addTearDown(third.close);
    expect(await third.syncQueueDao.queuedMutations(), hasLength(1));
    expect((await third.tasksDao.getTaskById('t-9'))!.title, 'Added later');
  });
}
