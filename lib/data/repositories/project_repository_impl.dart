import 'dart:async';
import 'dart:convert';

import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/clock.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/mutation_record.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/sync_enums.dart';
import '../../domain/entities/task.dart';
import '../../domain/repositories/project_repository.dart';
import '../db/app_database.dart';
import 'repository_support.dart';

/// Local-first [ProjectRepository] on Drift.
///
/// Same contract as `TaskRepositoryImpl`: row write + queue entry in one
/// transaction, watch-stream reads with derived [SyncStatus],
/// fire-and-forget [syncTrigger] after commit, [AppException]-only error
/// surface, and full determinism via the injected [Clock]/[IdGenerator].
///
/// Deleting a project tombstones the project and every non-deleted child
/// task in the same transaction, each with its own queued `delete` mutation,
/// so the cascade reaches the server for every child row.
class ProjectRepositoryImpl implements ProjectRepository {
  /// Creates the repository.
  ///
  /// [syncTrigger] is invoked (unawaited) after every committed mutation.
  ProjectRepositoryImpl({
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
  Stream<List<Project>> watchProjects() {
    return guardRepositoryStream(
      _db.projectsDao.watchProjects(maxAttempts: _maxAttempts),
    );
  }

  @override
  Stream<Project?> watchProject(String id) {
    return guardRepositoryStream(
      _db.projectsDao.watchProject(id, maxAttempts: _maxAttempts),
    );
  }

  @override
  Future<Project?> getProjectById(String id) {
    return guardRepository(() => _db.projectsDao.getProjectById(id));
  }

  // ---------------------------------------------------------------------------
  // Mutations (row + queue entry in one transaction)
  // ---------------------------------------------------------------------------

  @override
  Future<Project> createProject({
    required String name,
    required int colorValue,
  }) {
    return guardRepository(() async {
      final id = _idGenerator();
      final now = _nowMillis();
      final project = Project(
        id: id,
        name: name,
        colorValue: colorValue,
        createdAt: now,
        updatedAt: now,
        version: 1,
        syncStatus: SyncStatus.pending,
      );
      await _db.transaction(() async {
        await _db.projectsDao.upsertProject(project);
        await _db.syncQueueDao.enqueueMutation(
          _recordFor(
            type: MutationType.create,
            project: project,
            baseUpdatedAt: 0,
            baseVersion: 0,
          ),
        );
      });
      _triggerSync();
      return project;
    });
  }

  @override
  Future<Project> updateProject(Project project) {
    return guardRepository(() async {
      final base = await _requireProject(project.id);
      final now = _nowMillis();
      final updated = Project(
        id: base.id,
        name: project.name,
        colorValue: project.colorValue,
        createdAt: base.createdAt,
        updatedAt: now,
        version: base.version + 1,
        isDeleted: base.isDeleted,
        syncStatus: SyncStatus.pending,
      );
      await _db.transaction(() async {
        await _db.projectsDao.upsertProject(updated);
        await _db.syncQueueDao.enqueueMutation(
          _recordFor(
            type: MutationType.update,
            project: updated,
            baseUpdatedAt: base.updatedAt,
            baseVersion: base.version,
          ),
        );
      });
      _triggerSync();
      return updated;
    });
  }

  @override
  Future<void> deleteProject(String id) {
    return guardRepository(() async {
      final base = await _db.projectsDao.getProjectById(id);
      if (base == null) return; // deleting an unknown project is a no-op.
      final children = await _db.projectsDao.getTasksForProject(id);
      final now = _nowMillis();

      await _db.transaction(() async {
        // Project tombstone first (children keep their FK parent).
        final projectTombstone = Project(
          id: base.id,
          name: base.name,
          colorValue: base.colorValue,
          createdAt: base.createdAt,
          updatedAt: now,
          version: base.version + 1,
          isDeleted: true,
          syncStatus: SyncStatus.pending,
        );
        await _db.projectsDao.upsertProject(projectTombstone);
        await _db.syncQueueDao.enqueueMutation(
          _recordFor(
            type: MutationType.delete,
            project: projectTombstone,
            baseUpdatedAt: base.updatedAt,
            baseVersion: base.version,
          ),
        );

        // Cascade: tombstone every non-deleted child task, each with its own
        // queued delete mutation so the server deletes them all too.
        for (final child in children) {
          final taskTombstone = Task(
            id: child.id,
            projectId: child.projectId,
            title: child.title,
            notes: child.notes,
            priority: child.priority,
            dueDate: child.dueDate,
            isCompleted: child.isCompleted,
            createdAt: child.createdAt,
            updatedAt: now,
            version: child.version + 1,
            isDeleted: true,
            syncStatus: SyncStatus.pending,
          );
          await _db.tasksDao.upsertTask(taskTombstone);
          await _db.syncQueueDao.enqueueMutation(
            _taskRecordFor(
              type: MutationType.delete,
              task: taskTombstone,
              baseUpdatedAt: child.updatedAt,
              baseVersion: child.version,
            ),
          );
        }
      });
      _triggerSync();
    });
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Throws a mapped [DatabaseException] when [id] has no local row.
  Future<Project> _requireProject(String id) async {
    final project = await _db.projectsDao.getProjectById(id);
    if (project == null) {
      throw DatabaseException(
        cause: StateError('Project "$id" does not exist locally.'),
      );
    }
    return project;
  }

  /// Builds the queue entry for a project mutation.
  MutationRecord _recordFor({
    required MutationType type,
    required Project project,
    required int baseUpdatedAt,
    required int baseVersion,
  }) {
    return MutationRecord(
      mutationId: _idGenerator(),
      type: type,
      entityType: EntityType.project,
      entityId: project.id,
      payloadJson: jsonEncode(project.toJson()),
      baseUpdatedAt: baseUpdatedAt,
      baseVersion: baseVersion,
      clientTimestamp: project.updatedAt,
      queuedAt: project.updatedAt,
    );
  }

  /// Builds the queue entry for a task mutation (cascade deletes).
  MutationRecord _taskRecordFor({
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
