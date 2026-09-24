import 'dart:async';
import 'dart:convert';

import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/clock.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/mutation_record.dart';
import '../../domain/entities/sync_enums.dart';
import '../../domain/entities/task.dart';
import '../../domain/entities/task_filter.dart';
import '../../domain/repositories/task_repository.dart';
import '../db/app_database.dart';
import 'repository_support.dart';

/// Local-first [TaskRepository] on Drift.
///
/// Every mutation writes the task row AND enqueues its sync mutation inside
/// one database transaction, so the change is durable and instantly visible
/// offline — syncing is a *delivery* concern, never a precondition for
/// usability. After the transaction commits, the injected [syncTrigger] is
/// fired (fire-and-forget via `unawaited`) so the sync controller can drain
/// the queue opportunistically.
///
/// Reads are Drift watch streams re-emitting on every relevant table change,
/// with the per-record [SyncStatus] derived by the DAO's status subqueries
/// (failed beats syncing beats pending beats synced).
///
/// Determinism: ids come from the injected [IdGenerator], timestamps from
/// the injected [Clock]. Errors leaving this class are always
/// [AppException]s.
class TaskRepositoryImpl implements TaskRepository {
  /// Creates the repository.
  ///
  /// [syncTrigger] is invoked (unawaited) after every committed mutation —
  /// wire it to the sync controller's `syncNow` in the provider layer.
  TaskRepositoryImpl({
    required this._db,
    required this._clock,
    required this._idGenerator,
    required this._config,
    this._syncTrigger,
  });

  final AppDatabase _db;
  final Clock _clock;
  final IdGenerator _idGenerator;
  final AppConfig _config;
  final Future<void> Function()? _syncTrigger;

  int get _maxAttempts => _config.retryPolicy.maxAttempts;

  int _nowMillis() => _clock().millisecondsSinceEpoch;

  void _triggerSync() {
    final trigger = _syncTrigger;
    if (trigger != null) unawaited(trigger());
  }

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  @override
  Stream<List<Task>> watchTasks(TaskFilter filter) {
    return guardRepositoryStream(
      _db.tasksDao.watchTasks(filter, maxAttempts: _maxAttempts),
    );
  }

  @override
  Stream<Task?> watchTask(String id) {
    return guardRepositoryStream(
      _db.tasksDao.watchTask(id, maxAttempts: _maxAttempts),
    );
  }

  @override
  Future<Task?> getTaskById(String id) {
    return guardRepository(() => _db.tasksDao.getTaskById(id));
  }

  // ---------------------------------------------------------------------------
  // Mutations (row + queue entry in one transaction)
  // ---------------------------------------------------------------------------

  @override
  Future<Task> createTask({
    required String projectId,
    required String title,
    String? notes,
    TaskPriority priority = TaskPriority.medium,
    int? dueDate,
  }) {
    return guardRepository(() async {
      final id = _idGenerator();
      final now = _nowMillis();
      final task = Task(
        id: id,
        projectId: projectId,
        title: title,
        notes: notes,
        priority: priority,
        dueDate: dueDate,
        createdAt: now,
        updatedAt: now,
        version: 1,
        syncStatus: SyncStatus.pending,
      );
      await _db.transaction(() async {
        await _db.tasksDao.upsertTask(task);
        await _db.syncQueueDao.enqueueMutation(
          _recordFor(
            type: MutationType.create,
            task: task,
            baseUpdatedAt: 0,
            baseVersion: 0,
          ),
        );
      });
      _triggerSync();
      return task;
    });
  }

  @override
  Future<Task> updateTask(Task task) {
    return guardRepository(() async {
      final base = await _requireTask(task.id);
      return _applyEdit(base, task);
    });
  }

  @override
  Future<Task> setCompleted(String id, bool completed) {
    return guardRepository(() async {
      final base = await _requireTask(id);
      return _applyEdit(base, base.copyWith(isCompleted: completed));
    });
  }

  @override
  Future<void> deleteTask(String id) {
    return guardRepository(() async {
      final base = await _db.tasksDao.getTaskById(id);
      if (base == null) return; // deleting an unknown task is a no-op.
      final now = _nowMillis();
      final tombstone = _copyWithEditMeta(
        base,
        updatedAt: now,
        version: base.version + 1,
        isDeleted: true,
      );
      await _db.transaction(() async {
        await _db.tasksDao.upsertTask(tombstone);
        await _db.syncQueueDao.enqueueMutation(
          _recordFor(
            type: MutationType.delete,
            task: tombstone,
            baseUpdatedAt: base.updatedAt,
            baseVersion: base.version,
          ),
        );
      });
      _triggerSync();
    });
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Throws a mapped [DatabaseException] when [id] has no local row.
  Future<Task> _requireTask(String id) async {
    final task = await _db.tasksDao.getTaskById(id);
    if (task == null) {
      throw DatabaseException(
        cause: StateError('Task "$id" does not exist locally.'),
      );
    }
    return task;
  }

  /// Applies [edited]'s content on top of [base]: bumps `version` and
  /// `updatedAt` from the injected clock, writes the row and enqueues the
  /// `update` mutation (carrying the pre-edit base version) atomically.
  Future<Task> _applyEdit(Task base, Task edited) async {
    final now = _nowMillis();
    final updated = _copyWithEditMeta(
      edited,
      updatedAt: now,
      version: base.version + 1,
      isDeleted: base.isDeleted,
    );
    await _db.transaction(() async {
      await _db.tasksDao.upsertTask(updated);
      await _db.syncQueueDao.enqueueMutation(
        _recordFor(
          type: MutationType.update,
          task: updated,
          baseUpdatedAt: base.updatedAt,
          baseVersion: base.version,
        ),
      );
    });
    _triggerSync();
    return updated;
  }

  /// Builds the next row snapshot: content fields from [task], edit
  /// bookkeeping ([updatedAt], [version], [isDeleted]) from the arguments.
  Task _copyWithEditMeta(
    Task task, {
    required int updatedAt,
    required int version,
    required bool isDeleted,
  }) {
    return Task(
      id: task.id,
      projectId: task.projectId,
      title: task.title,
      notes: task.notes,
      priority: task.priority,
      dueDate: task.dueDate,
      isCompleted: task.isCompleted,
      createdAt: task.createdAt,
      updatedAt: updatedAt,
      version: version,
      isDeleted: isDeleted,
      syncStatus: SyncStatus.pending,
    );
  }

  /// Builds the queue entry for a task mutation.
  MutationRecord _recordFor({
    required MutationType type,
    required Task task,
    required int baseUpdatedAt,
    required int baseVersion,
  }) {
    return MutationRecord(
      mutationId: _idGenerator(),
      type: type,
      entityType: EntityType.task,
      entityId: task.id,
      payloadJson: jsonEncode(task.toJson()),
      baseUpdatedAt: baseUpdatedAt,
      baseVersion: baseVersion,
      clientTimestamp: task.updatedAt,
      queuedAt: task.updatedAt,
    );
  }
}
