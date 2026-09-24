import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/core/config/app_config.dart';
import 'package:offlineboard/core/errors/app_exception.dart';
import 'package:offlineboard/data/db/app_database.dart';
import 'package:offlineboard/data/remote/mock_sync_server.dart';
import 'package:offlineboard/data/remote/sync_api_client.dart';
import 'package:offlineboard/data/repositories/project_repository_impl.dart';
import 'package:offlineboard/data/repositories/task_repository_impl.dart';
import 'package:offlineboard/data/sync/conflict_resolver.dart';
import 'package:offlineboard/data/sync/sync_engine_impl.dart';
import 'package:offlineboard/domain/entities/conflict_resolution.dart';
import 'package:offlineboard/domain/entities/mutation_record.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/domain/entities/task_filter.dart';
import 'package:offlineboard/domain/sync/conflict_resolver.dart';
import 'package:offlineboard/domain/sync/sync_engine.dart';

// These tests talk to the REAL in-process mock sync server over Dio — so
// they MUST be plain `test()`s in the real async zone (testWidgets runs in
// a fake-async zone where real sockets never complete; see the A-3 lesson
// in the worklog). Drift runs on NativeDatabase.memory(); the clock and id
// generator are pinned, so every timestamp and ordering is deterministic.

/// Mutable pinned clock shared by db, engine, server and repositories.
class PinnedClock {
  DateTime _now = DateTime.utc(2025, 1, 1);

  /// Current pinned time.
  DateTime now() => _now;

  /// Moves the pinned time forward.
  void advance(Duration duration) => _now = _now.add(duration);
}

/// A resolver stub that always picks one fixed side — for exercising the
/// engine's handling of a verdict without depending on timestamps.
class FixedVerdictResolver implements ConflictResolver {
  const FixedVerdictResolver(this._verdict);

  final ConflictResolution _verdict;

  @override
  ConflictResolution resolve({
    required MutationRecord mutation,
    required ServerRecordSnapshot serverRecord,
  }) => _verdict;
}

/// Wires the whole data stack against one in-process server.
///
/// The sync trigger of the repositories only COUNTS (it does not run a
/// sync), so tests stay in full control of when the engine runs — the
/// fire-and-forget drain path is covered by the smoke tool and the
/// SyncController tests.
class SyncHarness {
  SyncHarness._(this.config) : clock = PinnedClock() {
    db = AppDatabase(NativeDatabase.memory());
    server = MockSyncServer(clock: clock.now);
    ids = SequentialIds();
    addTearDown(server.close);
    addTearDown(db.close);
  }

  /// Starts the server (binding its ephemeral port) and wires the client,
  /// engine and repositories against it.
  static Future<SyncHarness> start({
    AppConfig config = const AppConfig(),
    ConflictResolver? resolver,
  }) async {
    final harness = SyncHarness._(config);
    await harness.server.start();
    harness.client = SyncApiClient(
      baseUrl: harness.server.baseUrl,
      config: config,
    );
    harness.engine = SyncEngineImpl(
      db: harness.db,
      client: harness.client,
      resolver: resolver ?? const LastWriteWinsConflictResolver(),
      clock: harness.clock.now,
      config: config,
      idGenerator: harness.ids.next,
    );
    harness.projects = ProjectRepositoryImpl(
      db: harness.db,
      clock: harness.clock.now,
      idGenerator: harness.ids.next,
      config: config,
      syncTrigger: () async => harness.triggers++,
    );
    harness.tasks = TaskRepositoryImpl(
      db: harness.db,
      clock: harness.clock.now,
      idGenerator: harness.ids.next,
      config: config,
      syncTrigger: () async => harness.triggers++,
    );
    return harness;
  }

  /// App config (retry policy especially).
  final AppConfig config;

  /// The pinned clock.
  final PinnedClock clock;

  /// In-memory database (local source of truth).
  late final AppDatabase db;

  /// The simulated remote.
  late final MockSyncServer server;

  /// Wire client over Dio.
  late final SyncApiClient client;

  /// The engine under test.
  late final SyncEngine engine;

  /// Deterministic id source shared by repos and engine.
  late final SequentialIds ids;

  /// Local-first repositories wired to the same db (counting triggers).
  late final ProjectRepositoryImpl projects;
  late final TaskRepositoryImpl tasks;

  /// How often repositories fired the fire-and-forget sync trigger.
  int triggers = 0;

  /// Watch stream with the harness config's attempt budget.
  Stream<Task?> watchTask(String id) =>
      db.tasksDao.watchTask(id, maxAttempts: config.retryPolicy.maxAttempts);
}

/// Hand-out ids `seq-0`, `seq-1`, … — short, sortable, predictable.
class SequentialIds {
  int _counter = 0;

  /// The next id.
  String next() => 'seq-${_counter++}';
}

void main() {
  group('push: happy path', () {
    test('all applied → queue empties and rows flip to synced', () async {
      final harness = await SyncHarness.start();
      final project = await harness.projects.createProject(
        name: 'Personal',
        colorValue: 0xFF2E7D32,
      );
      final task = await harness.tasks.createTask(
        projectId: project.id,
        title: 'Buy groceries',
      );

      final outcome = await harness.engine.syncNow();

      expect(outcome.mutationsSent, 2);
      expect(outcome.applied, 2);
      expect(outcome.conflictsResolved, 0);
      expect(outcome.error, isNull);
      expect(await harness.engine.queuedMutationCount(), 0);

      // Rows are marked synced through the watch derivation.
      final watchedProject = await harness.db.projectsDao
          .watchProject(
            project.id,
            maxAttempts: harness.config.retryPolicy.maxAttempts,
          )
          .first;
      expect(watchedProject!.syncStatus, SyncStatus.synced);
      final watchedTask = await harness.watchTask(task.id).first;
      expect(watchedTask!.syncStatus, SyncStatus.synced);

      // Server state matches the local writes.
      expect(harness.server.projects[project.id]!['name'], 'Personal');
      expect(harness.server.tasks[task.id]!['title'], 'Buy groceries');
    });

    test(
      'repositories fire the fire-and-forget sync trigger per mutation',
      () async {
        final harness = await SyncHarness.start();
        await harness.projects.createProject(name: 'P', colorValue: 1);
        await harness.tasks.createTask(projectId: 'seq-0', title: 'T');

        expect(harness.triggers, 2);
      },
    );
  });

  group('push: conflicts', () {
    test(
      'LOCAL wins → local content kept and server converges in-round',
      () async {
        final harness = await SyncHarness.start();
        final project = await harness.projects.createProject(
          name: 'Personal',
          colorValue: 0xFF2E7D32,
        );
        await harness.engine.syncNow();

        // The server diverges (a concurrent editor bumped the version without
        // touching updatedAt), then we edit locally with a NEWER timestamp.
        harness.server.projects[project.id]!['version'] =
            (harness.server.projects[project.id]!['version'] as num) + 1;
        harness.clock.advance(const Duration(minutes: 1));
        await harness.projects.updateProject(
          (await harness.projects.getProjectById(project.id))!
              .copyWith(name: 'Renamed locally'),
        );

        final outcome = await harness.engine.syncNow();

        expect(outcome.conflictsResolved, 1);
        expect(outcome.applied, 1, reason: 'the corrected mutation delivered');
        expect(outcome.error, isNull);
        expect(
          harness.server.projects[project.id]!['name'],
          'Renamed locally',
          reason: 'server converged to the local winner',
        );
        expect(
          (await harness.projects.getProjectById(project.id))!.name,
          'Renamed locally',
        );
        expect(await harness.engine.queuedMutationCount(), 0);
      },
    );

    test(
      'SERVER wins → server content applied locally, mutation dropped',
      () async {
        final harness = await SyncHarness.start();
        final project = await harness.projects.createProject(
          name: 'Personal',
          colorValue: 0xFF2E7D32,
        );
        await harness.engine.syncNow();

        // A concurrent server write that is strictly newer than our edit.
        harness.clock.advance(const Duration(minutes: 1));
        await harness.projects.updateProject(
          (await harness.projects.getProjectById(project.id))!
              .copyWith(name: 'Local loser'),
        );
        final serverRecord = harness.server.projects[project.id]!;
        serverRecord['name'] = 'Server wins this time';
        serverRecord['version'] = (serverRecord['version'] as num) + 1;
        serverRecord['updatedAt'] =
            harness.clock.now().millisecondsSinceEpoch + 1000;

        final outcome = await harness.engine.syncNow();

        expect(outcome.conflictsResolved, 1);
        expect(
          (await harness.projects.getProjectById(project.id))!.name,
          'Server wins this time',
        );
        expect(
          await harness.engine.queuedMutationCount(),
          0,
          reason: 'the losing mutation was dropped, nothing re-armed',
        );
      },
    );

    test('a server that keeps conflicting is bounded — the last correction stays queued', () async {
      // Fixed local-wins resolver + conflictOnProjectId: every wave
      // conflicts and re-arms. The round must terminate (initial wave +
      // at most 3 follow-up waves) with the newest correction still
      // queued, and a clean sync after the injection is cleared drains
      // it — the queue can never grow unboundedly.
      final harness = await SyncHarness.start(
        resolver: const FixedVerdictResolver(ConflictResolution.localWins),
      );
      final project = await harness.projects.createProject(
        name: 'Personal',
        colorValue: 0xFF2E7D32,
      );
      await harness.engine.syncNow();
      expect(await harness.engine.queuedMutationCount(), 0);

      harness.server.conditions.conflictOnProjectId = project.id;
      harness.clock.advance(const Duration(minutes: 1));
      await harness.projects.updateProject(
        (await harness.projects.getProjectById(project.id))!
            .copyWith(name: 'Renamed locally'),
      );

      final outcome = await harness.engine.syncNow();

      expect(
        outcome.conflictsResolved,
        4,
        reason: 'initial wave + 3 bounded follow-up waves',
      );
      expect(outcome.error, isNull);
      expect(
        await harness.engine.queuedMutationCount(),
        1,
        reason: 'the last correction waits for the next round',
      );

      // Heal the server: the queued correction now applies cleanly.
      harness.server.conditions.reset();
      final second = await harness.engine.syncNow();
      expect(second.applied, 1);
      expect(second.error, isNull);
      expect(await harness.engine.queuedMutationCount(), 0);
      expect(harness.server.projects[project.id]!['name'], 'Renamed locally');
    });
  });

  group('push: rejection, transport failures, backoff', () {
    test(
      'rejected payload → attempts++ and stays queued with the reason',
      () async {
        final harness = await SyncHarness.start();
        final project = await harness.projects.createProject(
          name: 'P',
          colorValue: 1,
        );
        // Repositories do not validate — the empty title only gets rejected
        // by the server's payload validation.
        final task = await harness.tasks.createTask(
          projectId: project.id,
          title: '   ',
        );

        final outcome = await harness.engine.pushPending();

        expect(outcome.applied, 1, reason: 'the project applied');
        expect(outcome.rejected, 1);
        expect(outcome.error, isNull);

        final queue = await harness.engine.queuedMutations();
        expect(queue, hasLength(1));
        expect(queue.single.entityId, task.id);
        expect(queue.single.attempts, 1);
        expect(
          queue.single.lastError,
          'Task title must not be empty.',
          reason: 'the server reason is recorded as the diagnostic',
        );

        // The row is still pending (not failed — one attempt only).
        final watched = await harness.watchTask(task.id).first;
        expect(watched!.syncStatus, SyncStatus.pending);
      },
    );

    test(
      'server 5xx → whole batch marked attempted with backoff hint',
      () async {
        final harness = await SyncHarness.start();
        await harness.engine.pullSince(); // seeds → valid project ids
        final first = await harness.tasks.createTask(
          projectId: 'p-server-1',
          title: 'T1',
        );
        final second = await harness.tasks.createTask(
          projectId: 'p-server-1',
          title: 'T2',
        );

        harness.server.conditions.forceStatusNext = (count: 1, code: 503);
        final outcome = await harness.engine.pushPending();

        expect(outcome.applied, 0);
        expect(outcome.failed, 2);
        expect(outcome.error, isA<ServerException>());
        expect(
          (outcome.error! as AppException).userMessage,
          contains('our side'),
        );
        // Backoff hint for the next automatic attempt.
        expect(outcome.retryAfter, harness.config.retryPolicy.backoffFor(1));

        final queue = await harness.engine.queuedMutations();
        expect(queue, hasLength(2));
        expect(queue.every((record) => record.attempts == 1), isTrue);
        expect(queue.every((record) => record.lastError != null), isTrue);
        expect(
          queue.map((record) => record.entityId),
          containsAll([first.id, second.id]),
        );

        // Server recovers → the next sync drains the queue.
        harness.server.conditions.reset();
        final retry = await harness.engine.syncNow();
        expect(retry.applied, 2);
        expect(await harness.engine.queuedMutationCount(), 0);
      },
    );

    test(
      'timeout → attempts++ (TimeoutException), later retry converges',
      () async {
        final config = AppConfig(
          receiveTimeout: const Duration(milliseconds: 300),
        );
        final harness = await SyncHarness.start(config: config);
        await harness.engine.pullSince(); // seeds → valid project ids
        final task = await harness.tasks.createTask(
          projectId: 'p-server-1',
          title: 'T',
        );

        harness.server.conditions.latencyMs = 1500;
        final outcome = await harness.engine.pushPending();

        expect(outcome.failed, 1);
        expect(outcome.error, isA<TimeoutException>());
        expect((await harness.engine.queuedMutations()).single.attempts, 1);

        // Heal and retry: the duplicate push is idempotent (the server may
        // have applied the original after the client gave up).
        harness.server.conditions.reset();
        final retry = await harness.engine.syncNow();
        expect(retry.error, isNull);
        expect(await harness.engine.queuedMutationCount(), 0);
        expect(harness.server.tasks.containsKey(task.id), isTrue);
      },
    );

    test('dropped connection → NetworkException, attempts recorded', () async {
      final harness = await SyncHarness.start();
      await harness.engine.pullSince(); // seeds → valid project ids
      final task = await harness.tasks.createTask(
        projectId: 'p-server-1',
        title: 'T',
      );

      harness.server.conditions.dropConnection = true;
      final outcome = await harness.engine.pushPending();

      expect(outcome.failed, 1);
      expect(outcome.error, isA<NetworkException>());
      expect((await harness.engine.queuedMutations()).single.attempts, 1);

      harness.server.conditions.reset();
      expect((await harness.engine.syncNow()).applied, 1);
      expect(await harness.engine.queuedMutationCount(), 0);
      expect(harness.server.tasks.containsKey(task.id), isTrue);
    });

    test(
      'malformed response body → MalformedResponseException, attempts++',
      () async {
        final harness = await SyncHarness.start();
        await harness.engine.pullSince(); // seeds → valid project ids
        final task = await harness.tasks.createTask(
          projectId: 'p-server-1',
          title: 'T',
        );

        harness.server.conditions.malformedNext = 1;
        final outcome = await harness.engine.pushPending();

        expect(outcome.failed, 1);
        expect(outcome.error, isA<MalformedResponseException>());

        harness.server.conditions.reset();
        expect((await harness.engine.syncNow()).applied, 1);
        expect(await harness.engine.queuedMutationCount(), 0);
        expect(harness.server.tasks.containsKey(task.id), isTrue);
      },
    );
  });

  group('push: exhaustion and retryFailed', () {
    test(
      'maxAttempts exhausted → failed status, excluded from batches',
      () async {
        const config = AppConfig(
          retryPolicy: SyncRetryPolicy(
            maxAttempts: 2,
            maxBackoff: Duration(seconds: 1),
          ),
        );
        final harness = await SyncHarness.start(config: config);
        await harness.engine.pullSince(); // seeds → valid project ids
        final task = await harness.tasks.createTask(
          projectId: 'p-server-1',
          title: 'T',
        );

        // Two failed rounds exhaust the retry budget.
        harness.server.conditions.dropConnection = true;
        await harness.engine.pushPending();
        await harness.engine.pushPending();

        final queue = await harness.engine.queuedMutations();
        expect(queue, hasLength(1));
        expect(queue.single.attempts, 2);

        final watched = await harness.watchTask(task.id).first;
        expect(watched!.syncStatus, SyncStatus.failed);

        // Further syncs leave the exhausted mutation alone.
        final outcome = await harness.engine.pushPending();
        expect(outcome.mutationsSent, 0);
        expect(outcome.applied, 0);
        expect(
          outcome.retryAfter,
          isNull,
          reason: 'nothing left worth automatic retrying',
        );
        expect(await harness.engine.queuedMutationCount(), 1);
      },
    );

    test('retryFailed resets the budget and delivers successfully', () async {
      const config = AppConfig(
        retryPolicy: SyncRetryPolicy(
          maxAttempts: 2,
          maxBackoff: Duration(seconds: 1),
        ),
      );
      final harness = await SyncHarness.start(config: config);
      await harness.engine.pullSince(); // seeds → valid project ids
      final task = await harness.tasks.createTask(
        projectId: 'p-server-1',
        title: 'Retry me',
      );

      harness.server.conditions.dropConnection = true;
      await harness.engine.pushPending();
      await harness.engine.pushPending();
      expect((await harness.engine.queuedMutations()).single.attempts, 2);

      // Connectivity is back — the manual retry resets and delivers.
      harness.server.conditions.reset();
      final outcome = await harness.engine.retryFailed();

      expect(outcome.applied, 1);
      expect(await harness.engine.queuedMutationCount(), 0);
      expect(harness.server.tasks[task.id]!['title'], 'Retry me');
      final watched = await harness.watchTask(task.id).first;
      expect(watched!.syncStatus, SyncStatus.synced);
    });
  });

  group('push: idempotency', () {
    test('a replayed mutationId is acknowledged without re-applying', () async {
      final harness = await SyncHarness.start();
      final project = await harness.projects.createProject(
        name: 'P',
        colorValue: 1,
      );
      await harness.engine.syncNow();

      final task = await harness.tasks.createTask(
        projectId: project.id,
        title: 'Original',
      );
      final original = (await harness.engine.queuedMutations()).single;
      await harness.engine.syncNow();
      final appliedAt = harness.server.tasks[task.id]!['updatedAt'] as num;
      expect(await harness.engine.queuedMutationCount(), 0);

      // Simulate a lost acknowledgement: the same queue entry comes back
      // (crash between server apply and local dequeue).
      await harness.db.syncQueueDao.enqueueMutation(original);

      final outcome = await harness.engine.pushPending();

      expect(outcome.applied, 1, reason: 'duplicate acknowledged as applied');
      expect(await harness.engine.queuedMutationCount(), 0);
      expect(
        harness.server.tasks[task.id]!['updatedAt'],
        appliedAt,
        reason: 'the server did NOT re-apply the duplicate',
      );
    });
  });

  group('pull', () {
    test('applies server-side changes locally', () async {
      final harness = await SyncHarness.start();
      // First pull brings the seeded dataset in.
      final first = await harness.engine.pullSince();
      expect(first.projectsApplied, 2);
      expect(first.tasksApplied, 8);
      final local = await harness.db.tasksDao.getTaskById('t-server-2');
      expect(local!.title, 'Renew passport');

      // A server-side edit (newer than the cursor) arrives on the next pull.
      harness.clock.advance(const Duration(minutes: 1));
      final serverTask = harness.server.tasks['t-server-2']!;
      serverTask['title'] = 'Renew passport ASAP';
      serverTask['version'] = (serverTask['version'] as num) + 1;
      serverTask['updatedAt'] =
          harness.clock.now().millisecondsSinceEpoch + 500;

      final second = await harness.engine.pullSince();
      expect(second.tasksApplied, 1);
      final updated = await harness.db.tasksDao.getTaskById('t-server-2');
      expect(updated!.title, 'Renew passport ASAP');
      expect(updated.version, serverTask['version'] as int);
    });

    test('NEVER overwrites a row that has pending local mutations', () async {
      final harness = await SyncHarness.start();
      await harness.engine.pullSince();
      await harness.tasks.updateTask(
        (await harness.tasks.getTaskById('t-server-2'))!
            .copyWith(title: 'My local edit'),
      );
      expect(await harness.engine.queuedMutationCount(), 1);

      // The server writes something else for the same task.
      final serverTask = harness.server.tasks['t-server-2']!;
      serverTask['title'] = 'Server-side edit';
      serverTask['version'] = (serverTask['version'] as num) + 1;
      serverTask['updatedAt'] =
          harness.clock.now().millisecondsSinceEpoch + 5000;

      final outcome = await harness.engine.pullSince();

      expect(outcome.tasksApplied, 0);
      expect(outcome.skipped, 1, reason: 'the pending guard skipped the row');
      final local = await harness.db.tasksDao.getTaskById('t-server-2');
      expect(
        local!.title,
        'My local edit',
        reason: 'the local edit survives the pull',
      );
    });

    test(
      'skips server records that are not newer than the local copy',
      () async {
        final harness = await SyncHarness.start();
        await harness.engine.pullSince();

        // Rewind the cursor: the whole history comes back, including our own
        // pulled copies — none of them are newer, nothing re-applies.
        await harness.db.writeMeta(SyncEngineImpl.lastPullCursorKey, '0');
        final replay = await harness.engine.pullSince();

        expect(replay.projectsApplied, 0);
        expect(replay.tasksApplied, 0);
        expect(replay.skipped, 10);
      },
    );

    test('pull after own pushes does not clobber local rows', () async {
      final harness = await SyncHarness.start();
      final project = await harness.projects.createProject(
        name: 'Personal',
        colorValue: 0xFF2E7D32,
      );
      final task = await harness.tasks.createTask(
        projectId: project.id,
        title: 'Buy groceries',
      );
      final outcome = await harness.engine.syncNow();
      expect(outcome.applied, 2);

      // Replay everything from zero again: our own pushed records must not
      // overwrite (or reset the status of) the local rows.
      await harness.db.writeMeta(SyncEngineImpl.lastPullCursorKey, '0');
      final replay = await harness.engine.pullSince();

      expect(replay.skipped, greaterThanOrEqualTo(2));
      expect(replay.projectsApplied + replay.tasksApplied, 0);
      expect(
        (await harness.tasks.getTaskById(task.id))!.title,
        'Buy groceries',
      );
    });

    test('pull while offline throws the mapped network error', () async {
      final harness = await SyncHarness.start();
      harness.server.conditions.dropConnection = true;
      await expectLater(
        harness.engine.pullSince(),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  group('offline → online integration', () {
    test(
      'local-first work survives being offline, then drains on reconnect',
      () async {
        final harness = await SyncHarness.start();

        // Prime: one project created while ONLINE (so it exists server-side
        // and the local task rows have a synced FK parent).
        final project = await harness.projects.createProject(
          name: 'Personal',
          colorValue: 0xFF2E7D32,
        );
        await harness.engine.syncNow();
        expect(await harness.engine.queuedMutationCount(), 0);

        // Go offline.
        harness.server.conditions.dropConnection = true;
        harness.clock.advance(const Duration(minutes: 1));

        // Create 2 tasks, edit the first, delete the second — all offline.
        final toEdit = await harness.tasks.createTask(
          projectId: project.id,
          title: 'Initial title',
        );
        harness.clock.advance(const Duration(minutes: 1));
        final toDelete = await harness.tasks.createTask(
          projectId: project.id,
          title: 'Delete me',
        );
        harness.clock.advance(const Duration(minutes: 1));
        final edited = await harness.tasks.updateTask(
          (await harness.tasks.getTaskById(toEdit.id))!
              .copyWith(title: 'Edited while offline'),
        );
        expect(edited.version, 2);
        await harness.tasks.deleteTask(toDelete.id);

        // Everything is usable locally: the list shows the right rows…
        final visible = await harness.db.tasksDao
            .watchTasks(
              TaskFilter.all,
              maxAttempts: harness.config.retryPolicy.maxAttempts,
            )
            .first;
        final visibleIds = visible.map((t) => t.id).toSet();
        expect(visibleIds, contains(toEdit.id));
        expect(
          visibleIds,
          isNot(contains(toDelete.id)),
          reason: 'the deleted task disappears immediately',
        );
        // …with pending badges and the right content.
        final editedRow = visible.firstWhere((t) => t.id == toEdit.id);
        expect(editedRow.title, 'Edited while offline');
        expect(editedRow.syncStatus, SyncStatus.pending);

        // …and exactly four mutations are queued (2 creates + edit + delete).
        final queue = await harness.engine.queuedMutations();
        expect(queue, hasLength(4));
        expect(
          queue.map((record) => record.entityId),
          containsAll([toEdit.id, toDelete.id]),
        );
        // The edited task keeps its create and its update queued.
        final toEditTypes = queue
            .where((record) => record.entityId == toEdit.id)
            .map((record) => record.type)
            .toList();
        expect(toEditTypes, [MutationType.create, MutationType.update]);
        // The deleted task keeps its create and its tombstone queued.
        final toDeleteTypes = queue
            .where((record) => record.entityId == toDelete.id)
            .map((record) => record.type)
            .toList();
        expect(toDeleteTypes, [MutationType.create, MutationType.delete]);

        // Reconnect and drain.
        harness.server.conditions.reset();
        final outcome = await harness.engine.syncNow();

        expect(outcome.error, isNull);
        expect(outcome.applied, 4);
        expect(await harness.engine.queuedMutationCount(), 0);

        // The server converged to every local write.
        expect(
          harness.server.tasks[toEdit.id]!['title'],
          'Edited while offline',
        );
        expect(
          harness.server.tasks[toDelete.id]!['isDeleted'],
          isTrue,
          reason: 'the delete became a server-side tombstone',
        );
        // And the surviving local row is synced now.
        final afterSync = await harness.db.tasksDao
            .watchTasks(
              TaskFilter.all,
              maxAttempts: harness.config.retryPolicy.maxAttempts,
            )
            .first;
        expect(
          afterSync.firstWhere((t) => t.id == toEdit.id).syncStatus,
          SyncStatus.synced,
        );
      },
    );
  });
}
