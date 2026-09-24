// OfflineBoard sync pipeline smoke check (pure Dart, no Flutter bindings).
//
// Exercises the real database, repositories, sync engine, conflict resolver
// and in-process mock server end to end: local-first writes, push/pull,
// transport failure + retry, conflict resolution in both directions, and
// the project-delete cascade. Run with:
//
//   dart run tool/sync_smoke.dart
//
// Exits non-zero on the first failed expectation.

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';

import 'package:offlineboard/core/config/app_config.dart';
import 'package:offlineboard/core/utils/clock.dart';
import 'package:offlineboard/core/utils/id_generator.dart';
import 'package:offlineboard/data/db/app_database.dart';
import 'package:offlineboard/data/remote/mock_sync_server.dart';
import 'package:offlineboard/data/remote/sync_api_client.dart';
import 'package:offlineboard/data/repositories/project_repository_impl.dart';
import 'package:offlineboard/data/repositories/task_repository_impl.dart';
import 'package:offlineboard/data/sync/conflict_resolver.dart';
import 'package:offlineboard/data/sync/sync_engine_impl.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';

var _now = DateTime.utc(2025, 1, 1);

/// Deterministic clock the whole pipeline shares.
DateTime pinnedClock() => _now;

void advance(Duration d) => _now = _now.add(d);

int _checks = 0;

void check(String label, bool condition) {
  _checks++;
  if (!condition) {
    throw StateError('FAILED: $label');
  }
  stdout.writeln('  OK $label');
}

/// Polls [condition] until it holds (fire-and-forget triggers settle
/// asynchronously); throws after [timeout].
Future<void> until(
  FutureOr<bool> Function() condition, [
  Duration timeout = const Duration(seconds: 5),
]) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for a condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> main() async {
  final Clock clock = pinnedClock;
  final ids = TimeBasedIdGenerator(clock: clock);

  final db = AppDatabase(NativeDatabase.memory());
  final server = MockSyncServer(clock: clock);
  await server.start();

  const config = AppConfig();
  final client = SyncApiClient(baseUrl: server.baseUrl, config: config);
  final engine = SyncEngineImpl(
    db: db,
    client: client,
    resolver: const LastWriteWinsConflictResolver(),
    clock: clock,
    config: config,
    idGenerator: ids.next,
  );

  var triggeredSyncs = 0;
  Future<void> trigger() async {
    triggeredSyncs++;
    await engine.syncNow();
  }

  final projects = ProjectRepositoryImpl(
    db: db,
    clock: clock,
    idGenerator: ids.next,
    config: config,
    syncTrigger: trigger,
  );
  final tasks = TaskRepositoryImpl(
    db: db,
    clock: clock,
    idGenerator: ids.next,
    config: config,
    syncTrigger: trigger,
  );

  try {
    // ------------------------------------------------------------------
    stdout.writeln('1. local-first creation while offline');
    server.conditions.dropConnection = true;
    final project = await projects.createProject(
      name: 'Personal',
      colorValue: 0xFF2E7D32,
    );
    final task = await tasks.createTask(
      projectId: project.id,
      title: 'Buy groceries',
      priority: TaskPriority.high,
    );
    check('project row visible immediately (version 1)', project.version == 1);
    check(
      'project + task mutations queued',
      await engine.queuedMutationCount() == 2,
    );
    check(
      'sync was triggered fire-and-forget per mutation',
      triggeredSyncs == 2,
    );
    // The triggers run detached — wait for their attempts to land.
    await until(
      () async => await engine.queuedMutations().then(
        (entries) =>
            entries.length == 2 && entries.every((m) => m.attempts >= 1),
      ),
    );
    final queuedAfterOffline = await engine.queuedMutations();
    check(
      'offline attempts recorded with diagnostics',
      queuedAfterOffline.every((m) => m.attempts >= 1 && m.lastError != null),
    );
    server.conditions.reset();

    // ------------------------------------------------------------------
    stdout.writeln(
      '2. connectivity regained -> queue drains, statuses flip to synced',
    );
    final outcome = await engine.syncNow();
    check('all mutations applied', outcome.applied == 2);
    check('queue empty after drain', await engine.queuedMutationCount() == 0);
    check('server stored the project', server.projects.containsKey(project.id));
    check('server stored the task', server.tasks.containsKey(task.id));
    final watchedProject = await db.projectsDao
        .watchProject(project.id, maxAttempts: config.retryPolicy.maxAttempts)
        .first;
    stdout.writeln('    [debug] watched project: $watchedProject');
    stdout.writeln(
      '    [debug] getProjectById: ${await db.projectsDao.getProjectById(project.id)}',
    );
    stdout.writeln(
      '    [debug] raw rows: ${await db.customSelect('SELECT id, name, is_deleted FROM projects').get()}',
    );
    check(
      'watch stream derives synced status',
      watchedProject?.syncStatus == SyncStatus.synced,
    );

    // ------------------------------------------------------------------
    stdout.writeln('3. pull is idempotent (own pushes do not overwrite)');
    advance(const Duration(minutes: 1));
    final pull = await engine.pullSince();
    check(
      'nothing changed remotely since the cursor',
      pull.projectsApplied == 0,
    );
    check('no tasks changed remotely since the cursor', pull.tasksApplied == 0);
    // Replay the whole history (cursor rewind): our own pushed records come
    // back but must not clobber the local rows; the seeds pulled in step 2
    // are also unchanged, so nothing re-applies.
    await db.writeMeta(SyncEngineImpl.lastPullCursorKey, '0');
    final replay = await engine.pullSince();
    check('own pushed records skipped on replay', replay.skipped >= 2);
    check('nothing re-applied on replay', replay.projectsApplied == 0);
    final allProjects = await db.projectsDao
        .watchProjects(maxAttempts: config.retryPolicy.maxAttempts)
        .first;
    check(
      'seeded projects arrived earlier via pull (3 local)',
      allProjects.length == 3,
    );

    // ------------------------------------------------------------------
    stdout.writeln('4. pull guard: pending local edits are never overwritten');
    advance(const Duration(minutes: 1));
    server.projects[project.id]!['name'] = 'Server-side rename';
    server.projects[project.id]!['updatedAt'] = _now.millisecondsSinceEpoch;
    server.projects[project.id]!['version'] =
        (server.projects[project.id]!['version'] as num) + 1;
    final edited = await tasks.updateTask(
      (await tasks.getTaskById(task.id))!.copyWith(title: 'Buy vegetables'),
    );
    check('edit bumps version', edited.version == 2);
    await engine.pullSince();
    final taskAfterPull = await tasks.getTaskById(task.id);
    check(
      'pending local edit survived the pull',
      taskAfterPull!.title == 'Buy vegetables',
    );
    check(
      'edit queued for the server',
      await engine.queuedMutationCount() == 1,
    );
    await engine.syncNow();
    check(
      'edit delivered to the server',
      server.tasks[task.id]!['title'] == 'Buy vegetables',
    );
    check('queue empty again', await engine.queuedMutationCount() == 0);

    // ------------------------------------------------------------------
    stdout.writeln('5. conflict resolved LOCAL-WINS (client write newer)');
    advance(const Duration(minutes: 1));
    server.projects[project.id]!['version'] =
        (server.projects[project.id]!['version'] as num) + 1; // diverged
    await projects.updateProject(
      (await projects.getProjectById(project.id))!
          .copyWith(name: 'Renamed locally'),
    );
    final conflictOutcome = await engine.syncNow();
    check(
      'conflict was resolved (local winner re-pushed)',
      conflictOutcome.conflictsResolved >= 1,
    );
    check(
      'server converged to the local content',
      server.projects[project.id]!['name'] == 'Renamed locally',
    );
    check(
      'local row keeps the local content',
      (await projects.getProjectById(project.id))!.name == 'Renamed locally',
    );
    check('queue fully drained', await engine.queuedMutationCount() == 0);

    // ------------------------------------------------------------------
    stdout.writeln('6. conflict resolved SERVER-WINS (server write newer)');
    advance(const Duration(minutes: 1));
    final baseProject = await projects.getProjectById(project.id);
    server.projects[project.id]!['version'] =
        (server.projects[project.id]!['version'] as num) + 1;
    server.projects[project.id]!['name'] = 'Server wins this time';
    server.projects[project.id]!['updatedAt'] =
        _now.millisecondsSinceEpoch + 1000;
    await projects.updateProject(baseProject!.copyWith(name: 'Local loser'));
    await engine.syncNow();
    final resolved = await projects.getProjectById(project.id);
    check(
      'server content applied locally',
      resolved!.name == 'Server wins this time',
    );
    check(
      'mutation dropped after the server win',
      await engine.queuedMutationCount() == 0,
    );

    // ------------------------------------------------------------------
    stdout.writeln('7. project delete cascades to every child on the server');
    advance(const Duration(minutes: 1));
    await projects.deleteProject(project.id);
    check(
      'project + task deletes queued',
      await engine.queuedMutationCount() == 2,
    );
    await engine.syncNow();
    check(
      'server tombstoned the project',
      server.projects[project.id]!['isDeleted'] == true,
    );
    check(
      'server tombstoned the task',
      server.tasks[task.id]!['isDeleted'] == true,
    );
    check(
      'queue empty after cascade sync',
      await engine.queuedMutationCount() == 0,
    );
    final visibleProjects = await db.projectsDao
        .watchProjects(maxAttempts: config.retryPolicy.maxAttempts)
        .first;
    check('local list no longer contains the project', visibleProjects.isEmpty);

    stdout.writeln('All $_checks checks passed.');
  } finally {
    await server.close();
    await db.close();
  }
}
