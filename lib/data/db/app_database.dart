import 'package:drift/drift.dart';

import '../../domain/entities/mutation_record.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/sync_enums.dart';
import '../../domain/entities/task.dart';
import '../../domain/entities/task_filter.dart';
import '../mappers/entity_mappers.dart';

part 'app_database.g.dart';

/// Projects table — the local source of truth for project rows.
///
/// `updated_at` (UTC millis) and `version` drive the last-write-wins
/// conflict strategy; `is_deleted` marks tombstones so deletes can sync.
@DataClassName('ProjectRow')
class Projects extends Table {
  /// Client-generated opaque id.
  TextColumn get id => text()();

  /// Display name.
  TextColumn get name => text()();

  /// ARGB color int for the project accent.
  IntColumn get colorValue => integer()();

  /// Creation time (UTC millis).
  IntColumn get createdAt => integer()();

  /// Last modification time (UTC millis).
  IntColumn get updatedAt => integer()();

  /// Monotonic edit counter.
  IntColumn get version => integer()();

  /// Tombstone flag (soft delete).
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tasks table — the local source of truth for task rows.
///
/// Foreign key to `projects`; indexes cover the list-screen access paths
/// (per-project, completion, due date) and the sync-status subqueries
/// (see [TasksDao.watchTasks]).
@DataClassName('TaskRow')
class Tasks extends Table {
  /// Client-generated opaque id.
  TextColumn get id => text()();

  /// Owning project id.
  TextColumn get projectId => text()();

  /// Title (validated non-empty upstream).
  TextColumn get title => text()();

  /// Free-form notes, optional.
  TextColumn get notes => text().nullable()();

  /// [TaskPriority] index (low = 0 … urgent = 3).
  IntColumn get priority => integer()();

  /// Due date (UTC millis), optional.
  IntColumn get dueDate => integer().nullable()();

  /// Completion flag.
  BoolColumn get isCompleted => boolean().withDefault(const Constant(false))();

  /// Creation time (UTC millis).
  IntColumn get createdAt => integer()();

  /// Last modification time (UTC millis).
  IntColumn get updatedAt => integer()();

  /// Monotonic edit counter.
  IntColumn get version => integer()();

  /// Tombstone flag (soft delete).
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE CASCADE',
  ];
}

/// The durable sync queue — one row per not-yet-confirmed local mutation.
///
/// This table IS the offline capability: it survives restarts, orders the
/// push batches, tracks attempts/backoff and drives the per-record sync
/// badges via correlated subqueries.
@DataClassName('PendingMutationRow')
class PendingMutations extends Table {
  /// Drift autoincrement primary key (queue ordering is `queued_at`, this
  /// is only the row handle used by the engine).
  IntColumn get id => integer().autoIncrement()();

  /// Client-generated unique mutation id — the idempotency key the server
  /// remembers. The table's `UNIQUE (mutation_id, entity_id)` key dedupes
  /// local double-enqueues.
  TextColumn get mutationId => text()();

  /// [MutationType] index.
  IntColumn get type => integer()();

  /// [EntityType] index.
  IntColumn get entityType => integer()();

  /// Id of the affected record.
  TextColumn get entityId => text()();

  /// Full new record state as JSON text.
  TextColumn get payloadJson => text()();

  /// `updated_at` the local edit was applied on top of.
  IntColumn get baseUpdatedAt => integer()();

  /// `version` the local edit was applied on top of.
  IntColumn get baseVersion => integer()();

  /// When the local edit happened (UTC millis).
  IntColumn get clientTimestamp => integer()();

  /// When the mutation entered the queue (UTC millis) — push order.
  IntColumn get queuedAt => integer()();

  /// Failed push attempts so far.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// Last failure reason, for diagnostics.
  TextColumn get lastError => text().nullable()();

  /// Set by the engine while the mutation is part of an in-flight batch —
  /// surfaces rows as `SyncStatus.syncing`.
  BoolColumn get isSyncing => boolean().withDefault(const Constant(false))();

  @override
  List<Set<Column>> get uniqueKeys => [
    {mutationId, entityId},
  ];
}

/// Small key/value store for sync bookkeeping (`lastPullAt`, …).
@DataClassName('SyncMetaRow')
class SyncMeta extends Table {
  /// Meta key.
  TextColumn get metaKey => text()();

  /// Meta value (serialized).
  TextColumn get metaValue => text()();

  @override
  Set<Column> get primaryKey => {metaKey};
}

/// The Drift database behind OfflineBoard.
///
/// The constructor accepts a [QueryExecutor] so tests run on
/// `NativeDatabase.memory()` while the app opens a file through
/// `path_provider` (see `presentation/providers/database_provider.dart` —
/// deliberately *not* here, to keep this class platform-free).
@DriftDatabase(
  tables: [Projects, Tasks, PendingMutations, SyncMeta],
  daos: [ProjectsDao, TasksDao, SyncQueueDao],
)
class AppDatabase extends _$AppDatabase {
  /// Creates the database on the given [QueryExecutor].
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      // Access paths for the list screens and the sync-status subqueries.
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks (project_id, '
        'is_deleted)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks '
        '(is_completed, is_deleted)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_tasks_due ON tasks (is_deleted, '
        'due_date)',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_queue_entity ON pending_mutations '
        '(entity_id, is_syncing, attempts)',
      );
    },
    beforeOpen: (details) async {
      // Belt & braces for the tasks → projects foreign key.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Reads a sync metadata value.
  Future<String?> readMeta(String key) async {
    final row = await (select(
      syncMeta,
    )..where((m) => m.metaKey.equals(key))).getSingleOrNull();
    return row?.metaValue;
  }

  /// Writes a sync metadata value (upsert).
  Future<void> writeMeta(String key, String value) async {
    await into(syncMeta)
        .insertOnConflictUpdate(SyncMetaRow(metaKey: key, metaValue: value));
  }
}

/// Project queries.
///
/// Watch methods join the queue status via correlated subqueries so the
/// per-record [SyncStatus] is always a single consistent snapshot.
@DriftAccessor(tables: [Projects, Tasks, PendingMutations, SyncMeta])
class ProjectsDao extends DatabaseAccessor<AppDatabase>
    with _$ProjectsDaoMixin {
  /// Creates the dao attached to the given database.
  ProjectsDao(super.db);

  static const _statusColumns =
      '(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = p.id) '
      'AS queueCount, '
      '(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = p.id '
      'AND pm.is_syncing = 1) AS syncingCount, '
      '(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = p.id '
      'AND pm.attempts >= ?) AS failedCount';

  /// Watches non-deleted projects (ordered by name) with derived sync
  /// status.
  Stream<List<Project>> watchProjects({required int maxAttempts}) {
    return db
        .customSelect(
          'SELECT p.id AS id, p.name AS name, p.color_value AS colorValue, '
          'p.created_at AS createdAt, p.updated_at AS updatedAt, '
          'p.version AS version, p.is_deleted AS isDeleted, '
          '$_statusColumns '
          'FROM projects p '
          'WHERE p.is_deleted = 0 '
          'ORDER BY p.name COLLATE NOCASE ASC',
          variables: [Variable.withInt(maxAttempts)],
          readsFrom: {projects, pendingMutations},
        )
        .watch()
        .map((rows) => [for (final row in rows) projectFromQueryRow(row)]);
  }

  /// Watches a single project by id (tombstones included).
  Stream<Project?> watchProject(String id, {required int maxAttempts}) {
    return db
        .customSelect(
          'SELECT p.id AS id, p.name AS name, p.color_value AS colorValue, '
          'p.created_at AS createdAt, p.updated_at AS updatedAt, '
          'p.version AS version, p.is_deleted AS isDeleted, '
          '$_statusColumns '
          'FROM projects p '
          'WHERE p.id = ?',
          variables: [Variable.withString(id), Variable.withInt(maxAttempts)],
          readsFrom: {projects, pendingMutations},
        )
        .watch()
        .map((rows) => rows.isEmpty ? null : projectFromQueryRow(rows.first));
  }

  /// Fetches a project by id (no queue join; status defaults to `synced`).
  Future<Project?> getProjectById(String id) async {
    final row = await (select(
      projects,
    )..where((p) => p.id.equals(id))).getSingleOrNull();
    return row == null ? null : projectFromRow(row);
  }

  /// Inserts or replaces the project row.
  Future<void> upsertProject(Project project) async {
    await into(projects).insertOnConflictUpdate(projectToCompanion(project));
  }

  /// Non-deleted tasks of a project (used by the cascade delete).
  Future<List<Task>> getTasksForProject(String projectId) async {
    final query = select(tasks)
      ..where((t) => t.projectId.equals(projectId) & t.isDeleted.equals(false));
    final rows = await query.get();
    return [for (final row in rows) taskFromRow(row)];
  }
}

/// Task queries.
///
/// [watchTasks] implements the whole filter contract of
/// `TaskRepository.watchTasks` in one parameterized query, with the
/// sync-status subqueries attached.
@DriftAccessor(tables: [Projects, Tasks, PendingMutations, SyncMeta])
class TasksDao extends DatabaseAccessor<AppDatabase> with _$TasksDaoMixin {
  /// Creates the dao attached to the given database.
  TasksDao(super.db);

  static const _taskColumns =
      't.id AS id, t.project_id AS projectId, t.title AS title, '
      't.notes AS notes, t.priority AS priority, t.due_date AS dueDate, '
      't.is_completed AS isCompleted, t.created_at AS createdAt, '
      't.updated_at AS updatedAt, t.version AS version, '
      't.is_deleted AS isDeleted';

  static const _statusColumns =
      '(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = t.id) '
      'AS queueCount, '
      '(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = t.id '
      'AND pm.is_syncing = 1) AS syncingCount, '
      '(SELECT COUNT(*) FROM pending_mutations pm WHERE pm.entity_id = t.id '
      'AND pm.attempts >= ?) AS failedCount';

  static const _orderBy =
      'ORDER BY t.is_completed ASC, t.due_date IS NULL ASC, t.due_date ASC, '
      't.priority DESC, t.title COLLATE NOCASE ASC';

  /// Watches non-deleted tasks matching [filter] with derived sync status.
  ///
  /// Order: incomplete first, due date (nulls last), urgent priority first,
  /// then title. All user input travels as SQL variables — never
  /// interpolated.
  Stream<List<Task>> watchTasks(TaskFilter filter, {required int maxAttempts}) {
    final conditions = <String>['t.is_deleted = 0'];
    final variables = <Variable>[Variable.withInt(maxAttempts)];

    if (filter.projectId case final projectId?) {
      conditions.add('t.project_id = ?');
      variables.add(Variable.withString(projectId));
    }
    switch (filter.completion) {
      case TaskCompletionFilter.incomplete:
        conditions.add('t.is_completed = 0');
      case TaskCompletionFilter.completed:
        conditions.add('t.is_completed = 1');
      case TaskCompletionFilter.all:
        break;
    }
    if (filter.priority case final priority?) {
      conditions.add('t.priority = ?');
      variables.add(Variable.withInt(priority.index));
    }
    if (filter.dueBefore case final dueBefore?) {
      conditions.add('t.due_date IS NOT NULL AND t.due_date <= ?');
      variables.add(Variable.withInt(dueBefore));
    }
    final search = filter.search.trim();
    if (search.isNotEmpty) {
      conditions.add("lower(t.title) LIKE '%' || lower(?) || '%'");
      variables.add(Variable.withString(search));
    }

    return db
        .customSelect(
          'SELECT $_taskColumns, $_statusColumns '
          'FROM tasks t '
          'WHERE ${conditions.join(' AND ')} '
          '$_orderBy',
          variables: variables,
          readsFrom: {tasks, pendingMutations},
        )
        .watch()
        .map((rows) => [for (final row in rows) taskFromQueryRow(row)]);
  }

  /// Watches a single task by id (tombstones included) with sync status.
  Stream<Task?> watchTask(String id, {required int maxAttempts}) {
    return db
        .customSelect(
          'SELECT $_taskColumns, $_statusColumns '
          'FROM tasks t '
          'WHERE t.id = ?',
          variables: [Variable.withString(id), Variable.withInt(maxAttempts)],
          readsFrom: {tasks, pendingMutations},
        )
        .watch()
        .map((rows) => rows.isEmpty ? null : taskFromQueryRow(rows.first));
  }

  /// Watches non-deleted tasks that have at least one queued mutation —
  /// the "unsynced changes" view (join on the queue).
  Stream<List<Task>> watchUnsyncedTasks({required int maxAttempts}) {
    return db
        .customSelect(
          'SELECT $_taskColumns, $_statusColumns '
          'FROM tasks t '
          'WHERE t.is_deleted = 0 AND EXISTS ('
          '  SELECT 1 FROM pending_mutations pm WHERE pm.entity_id = t.id) '
          '$_orderBy',
          variables: [Variable.withInt(maxAttempts)],
          readsFrom: {tasks, pendingMutations},
        )
        .watch()
        .map((rows) => [for (final row in rows) taskFromQueryRow(row)]);
  }

  /// Fetches a task by id (no queue join; status defaults to `synced`).
  Future<Task?> getTaskById(String id) async {
    final row = await (select(
      tasks,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : taskFromRow(row);
  }

  /// Fetches every task row (tombstones included) for an entity id list —
  /// engine-side conflict lookups.
  Future<Map<String, Task>> getTasksByIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final rows = await (select(tasks)..where((t) => t.id.isIn(ids))).get();
    return {for (final row in rows) row.id: taskFromRow(row)};
  }

  /// Inserts or replaces the task row.
  Future<void> upsertTask(Task task) async {
    await into(tasks).insertOnConflictUpdate(taskToCompanion(task));
  }
}

/// Sync-queue operations (the engine's view of the queue).
@DriftAccessor(tables: [Projects, Tasks, PendingMutations, SyncMeta])
class SyncQueueDao extends DatabaseAccessor<AppDatabase>
    with _$SyncQueueDaoMixin {
  /// Creates the dao attached to the given database.
  SyncQueueDao(super.db);

  /// Enqueues a mutation. The `UNIQUE (mutation_id, entity_id)` key makes
  /// duplicate enqueues a no-op (idempotent queue writes).
  Future<bool> enqueueMutation(MutationRecord record) async {
    final query = select(pendingMutations)
      ..where((t) => t.mutationId.equals(record.mutationId));
    final existing = await query.getSingleOrNull();
    if (existing != null) return false;
    await into(pendingMutations).insert(mutationToCompanion(record));
    return true;
  }

  /// Next push batch, oldest first (FIFO keeps server-side ordering sane).
  Future<List<PendingMutationRow>> nextBatch({required int limit}) {
    final query = select(pendingMutations)
      ..orderBy([
        (t) => OrderingTerm.asc(t.queuedAt),
        (t) => OrderingTerm.asc(t.id),
      ])
      ..limit(limit);
    return query.get();
  }

  /// Marks rows as part of an in-flight batch (`SyncStatus.syncing`).
  Future<void> markSyncing(List<int> rowIds) async {
    if (rowIds.isEmpty) return;
    final query = update(pendingMutations)..where((t) => t.id.isIn(rowIds));
    await query.write(const PendingMutationsCompanion(isSyncing: Value(true)));
  }

  /// Records a failed attempt for every row in [rowIds]: `attempts + 1`,
  /// [error] as the diagnostic message, syncing flag cleared.
  Future<void> markAttempted(List<int> rowIds, String error) async {
    if (rowIds.isEmpty) return;
    final placeholders = List.filled(rowIds.length, '?').join(', ');
    await customUpdate(
      'UPDATE pending_mutations SET attempts = attempts + 1, '
      'last_error = ?, is_syncing = 0 WHERE id IN ($placeholders)',
      variables: [
        Variable.withString(error),
        for (final id in rowIds) Variable.withInt(id),
      ],
    );
  }

  /// Removes mutations after they were applied/resolved.
  Future<void> removeMutations(List<int> rowIds) async {
    if (rowIds.isEmpty) return;
    await (delete(pendingMutations)..where((t) => t.id.isIn(rowIds))).go();
  }

  /// Removes every queued mutation for an entity (after a resolved
  /// conflict leaves superseded entries behind).
  Future<void> removeMutationsForEntity(String entityId) async {
    final query = delete(pendingMutations)
      ..where((t) => t.entityId.equals(entityId));
    await query.go();
  }

  /// Live size of the queue (pending + syncing + failed) — drives the
  /// badge provider.
  Stream<int> watchCount() {
    final count = countAll();
    return (selectOnly(
      pendingMutations,
    )..addColumns([count])).watchSingle().map((row) => row.read(count) ?? 0);
  }

  /// Whether the entity has queued mutations — the pull guard that never
  /// overwrites pending local edits.
  Future<bool> hasPendingFor(String entityId) async {
    final count = countAll();
    final query = selectOnly(pendingMutations)
      ..addColumns([count])
      ..where(pendingMutations.entityId.equals(entityId));
    final row = await query.getSingle();
    return (row.read(count) ?? 0) > 0;
  }

  /// Clears `is_syncing` for the whole queue (engine startup / recovery
  /// from a crashed sync round).
  Future<void> clearSyncingFlags() async {
    await update(pendingMutations)
        .write(const PendingMutationsCompanion(isSyncing: Value(false)));
  }

  /// Resets the failure bookkeeping of exhausted mutations so they can be
  /// retried manually (attempts → 0, error cleared).
  Future<void> resetFailures() async {
    final query = update(pendingMutations)
      ..where((t) => t.attempts.isBiggerThanValue(0));
    await query.write(
      const PendingMutationsCompanion(
        attempts: Value(0),
        lastError: Value(null),
        isSyncing: Value(false),
      ),
    );
  }

  /// Queue entries as domain records (diagnostics / debug screens).
  Future<List<MutationRecord>> queuedMutations() async {
    final query = select(pendingMutations)
      ..orderBy([
        (t) => OrderingTerm.asc(t.queuedAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
    final rows = await query.get();
    return [for (final row in rows) mutationFromRow(row)];
  }
}
