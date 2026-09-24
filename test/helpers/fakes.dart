import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/core/errors/app_exception.dart';
import 'package:offlineboard/data/db/app_database.dart';
import 'package:offlineboard/domain/entities/mutation_record.dart';
import 'package:offlineboard/domain/entities/project.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/domain/entities/task_filter.dart';
import 'package:offlineboard/domain/repositories/project_repository.dart';
import 'package:offlineboard/domain/repositories/task_repository.dart';
import 'package:offlineboard/domain/sync/sync_engine.dart';
import 'package:offlineboard/presentation/providers/connectivity_provider.dart';
import 'package:offlineboard/presentation/providers/core_providers.dart';
import 'package:offlineboard/presentation/providers/database_provider.dart';
import 'package:offlineboard/presentation/providers/sync_engine_provider.dart';

/// Mutable pinned clock for provider-overridden tests.
class MutablePinnedClock {
  DateTime _now = DateTime.utc(2025, 1, 1);

  /// Current pinned time.
  DateTime now() => _now;

  /// Moves the pinned time forward.
  void advance(Duration duration) => _now = _now.add(duration);
}

/// Deterministic sequential id source (`s-0`, `s-1`, …).
class SequentialIdSource {
  int _counter = 0;

  /// The next id.
  String next() => 's-${_counter++}';
}

/// Scriptable [ConnectivityService] for tests.
class FakeConnectivityService extends ConnectivityService {
  /// Creates the service in the given state.
  FakeConnectivityService(bool initial) : online = initial;

  /// Current connectivity.
  bool online;

  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  bool get isOnline => online;

  @override
  Stream<bool> get onConnectivityChanged => _changes.stream;

  /// Flips the state and notifies listeners.
  void emit(bool value) {
    online = value;
    _changes.add(value);
  }

  /// Releases the stream.
  Future<void> dispose() => _changes.close();
}

/// Scriptable [SyncEngine] stand-in: records calls and replays outcomes.
class FakeSyncEngine implements SyncEngine {
  /// Creates the engine. [queuedMutationCountValue] feeds the
  /// `SyncSyncing(queuedCount)` state; [syncNowOutcome] /
  /// [retryFailedOutcome] are replayed per call (success when `null`).
  FakeSyncEngine({
    this.queuedMutationCountValue = 0,
    this.syncNowOutcome,
    this.retryFailedOutcome,
  });

  /// What `queuedMutationCount()` reports.
  int queuedMutationCountValue;

  /// Outcome replayed by [syncNow] (`null` = clean success).
  SyncOutcome? syncNowOutcome;

  /// Outcome replayed by [retryFailed] (`null` = clean success).
  SyncOutcome? retryFailedOutcome;

  /// Number of `syncNow` calls.
  int syncNowCalls = 0;

  /// Number of `retryFailed` calls.
  int retryFailedCalls = 0;

  /// When set, `syncNow` waits for this future before answering — lets
  /// tests observe the `syncing` state.
  Completer<void>? syncNowGate;

  /// Number of `pullSince` calls.
  int pullSinceCalls = 0;

  static const _success = SyncOutcome();

  @override
  Future<SyncOutcome> syncNow() async {
    syncNowCalls++;
    final gate = syncNowGate;
    if (gate != null) await gate.future;
    return syncNowOutcome ?? _success;
  }

  @override
  Future<SyncOutcome> pushPending() async => syncNowOutcome ?? _success;

  @override
  Future<PullOutcome> pullSince() async {
    pullSinceCalls++;
    return const PullOutcome();
  }

  @override
  Future<SyncOutcome> retryFailed() async {
    retryFailedCalls++;
    return retryFailedOutcome ?? _success;
  }

  @override
  Future<int> queuedMutationCount() async => queuedMutationCountValue;

  @override
  Future<List<MutationRecord>> queuedMutations() async => const [];
}

/// A [TaskRepository] fake that records every watched filter and replays
/// a controllable task list — for counting re-queries (debounce tests).
class RecordingTaskRepository implements TaskRepository {
  /// Every filter ever passed to [watchTasks], in order.
  final List<TaskFilter> watchedFilters = <TaskFilter>[];

  final StreamController<List<Task>> _tasks =
      StreamController<List<Task>>.broadcast();

  /// Emits a new task list to every active watcher.
  void emit(List<Task> tasks) => _tasks.add(tasks);

  /// Releases the stream.
  ///
  /// Fire-and-forget on purpose: a broadcast controller's `close()` future
  /// only completes once the done event is delivered to an unpaused
  /// listener, and Riverpod may keep its internal subscription paused —
  /// awaiting it can hang a test teardown forever.
  Future<void> dispose() async {
    unawaited(_tasks.close());
  }

  @override
  Stream<List<Task>> watchTasks(TaskFilter filter) {
    watchedFilters.add(filter);
    return _tasks.stream;
  }

  @override
  Stream<Task?> watchTask(String id) => const Stream.empty();

  @override
  Future<Task?> getTaskById(String id) async => null;

  @override
  Future<Task> createTask({
    required String projectId,
    required String title,
    String? notes,
    TaskPriority priority = TaskPriority.medium,
    int? dueDate,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Task> updateTask(Task task) async => throw UnimplementedError();

  @override
  Future<Task> setCompleted(String id, bool completed) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteTask(String id) async => throw UnimplementedError();
}

/// In-memory [TaskRepository] for widget tests — no drift, no platform
/// channels, no real HTTP.
///
/// `watchTasks` replays the current list to every new listener (like a
/// drift watch query) and re-emits on [emit]. The filter's SQL dimensions
/// are the real repository's job and are covered by the DAO tests — this
/// fake only honors deletion.
class FakeTaskRepository implements TaskRepository {
  final Map<String, Task> _tasks = {};

  /// Tasks passed to [createTask], in order.
  final List<Task> createdTasks = [];

  /// Tasks passed to [updateTask], in order.
  final List<Task> updatedTasks = [];

  /// `(id, completed)` pairs passed to [setCompleted], in order.
  final List<(String, bool)> completedCalls = [];

  /// Ids passed to [deleteTask], in order.
  final List<String> deletedIds = [];

  late final StreamController<List<Task>> _list;

  /// Creates the fake preloaded with [initial].
  FakeTaskRepository([List<Task> initial = const []]) {
    for (final task in initial) {
      _tasks[task.id] = task;
    }
    _list = StreamController<List<Task>>.broadcast(onListen: _replay);
  }

  /// The current non-deleted tasks.
  List<Task> get visibleTasks =>
      _tasks.values.where((task) => !task.isDeleted).toList();

  /// Re-emits the current list to every watcher.
  void emit() => _list.add(visibleTasks);

  void _replay() {
    scheduleMicrotask(() {
      if (!_list.isClosed) _list.add(visibleTasks);
    });
  }

  @override
  Stream<List<Task>> watchTasks(TaskFilter filter) => _list.stream;

  @override
  Stream<Task?> watchTask(String id) =>
      Stream.value(_tasks[id]).where((task) => task != null || true);

  @override
  Future<Task?> getTaskById(String id) async => _tasks[id];

  @override
  Future<Task> createTask({
    required String projectId,
    required String title,
    String? notes,
    TaskPriority priority = TaskPriority.medium,
    int? dueDate,
  }) async {
    final task = Task(
      id: 'created-${createdTasks.length}',
      projectId: projectId,
      title: title,
      notes: notes,
      priority: priority,
      dueDate: dueDate,
      createdAt: 0,
      updatedAt: 0,
      version: 1,
      syncStatus: SyncStatus.pending,
    );
    createdTasks.add(task);
    _tasks[task.id] = task;
    return task;
  }

  @override
  Future<Task> updateTask(Task task) async {
    updatedTasks.add(task);
    _tasks[task.id] = task;
    return task;
  }

  @override
  Future<Task> setCompleted(String id, bool completed) async {
    completedCalls.add((id, completed));
    final task = _tasks[id]!;
    final updated = task.copyWith(
      isCompleted: completed,
      version: task.version + 1,
      updatedAt: task.updatedAt + 1,
    );
    _tasks[id] = updated;
    emit();
    return updated;
  }

  @override
  Future<void> deleteTask(String id) async {
    deletedIds.add(id);
    final task = _tasks[id];
    if (task != null) {
      _tasks[id] = task.copyWith(isDeleted: true);
      emit();
    }
  }
}

/// In-memory [ProjectRepository] for widget tests.
///
/// Same replay semantics as [FakeTaskRepository].
class FakeProjectRepository implements ProjectRepository {
  final Map<String, Project> _projects = {};

  /// Projects passed to [createProject], in order.
  final List<Project> createdProjects = [];

  late final StreamController<List<Project>> _list;

  /// Creates the fake preloaded with [initial].
  FakeProjectRepository([List<Project> initial = const []]) {
    for (final project in initial) {
      _projects[project.id] = project;
    }
    _list = StreamController<List<Project>>.broadcast(onListen: _replay);
  }

  /// The current non-deleted projects.
  List<Project> get visibleProjects =>
      _projects.values.where((project) => !project.isDeleted).toList();

  /// Re-emits the current list to every watcher.
  void emit() => _list.add(visibleProjects);

  void _replay() {
    scheduleMicrotask(() {
      if (!_list.isClosed) _list.add(visibleProjects);
    });
  }

  @override
  Stream<List<Project>> watchProjects() => _list.stream;

  @override
  Stream<Project?> watchProject(String id) =>
      Stream.value(_projects[id]).where((project) => project != null || true);

  @override
  Future<Project?> getProjectById(String id) async => _projects[id];

  @override
  Future<Project> createProject({
    required String name,
    required int colorValue,
  }) async {
    final project = Project(
      id: 'created-${createdProjects.length}',
      name: name,
      colorValue: colorValue,
      createdAt: 0,
      updatedAt: 0,
      version: 1,
    );
    createdProjects.add(project);
    _projects[project.id] = project;
    return project;
  }

  @override
  Future<Project> updateProject(Project project) async {
    _projects[project.id] = project;
    return project;
  }

  @override
  Future<void> deleteProject(String id) async {
    final project = _projects[id];
    if (project != null) {
      _projects[id] = project.copyWith(isDeleted: true);
      emit();
    }
  }
}

/// Builds a [ProviderContainer] over an in-memory drift database with a
/// pinned clock, deterministic ids and the given engine/connectivity
/// fakes — the shared wiring of the state tests. The container (and the
/// database inside it) is disposed via `addTearDown`.
ProviderContainer stateTestContainer({
  MutablePinnedClock? clock,
  FakeSyncEngine? engine,
  FakeConnectivityService? connectivity,
}) {
  final pinned = clock ?? MutablePinnedClock();
  final ids = SequentialIdSource();
  // Always fake connectivity — the real service talks to platform channels.
  final fakeConnectivity = connectivity ?? FakeConnectivityService(true);
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(pinned.now),
      idGeneratorProvider.overrideWithValue(ids.next),
      databaseProvider.overrideWith((ref) {
        final db = AppDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      connectivityServiceProvider.overrideWithValue(fakeConnectivity),
      if (engine != null)
        syncEngineProvider.overrideWith((ref) async => engine),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A failing outcome carrying the given mapped error.
SyncOutcome failedOutcome(AppException error, {Duration? retryAfter}) {
  return SyncOutcome(failed: 1, error: error, retryAfter: retryAfter);
}
