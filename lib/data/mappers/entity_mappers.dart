import 'package:drift/drift.dart';

import '../../domain/entities/mutation_record.dart';
import '../../domain/entities/project.dart';
import '../../domain/entities/sync_enums.dart';
import '../../domain/entities/task.dart';
import '../db/app_database.dart';

/// Conversions between domain entities, Drift rows/companions and raw
/// `QueryRow`s of the custom status queries.
///
/// Enums are stored as indexes (fast SQL filtering) and serialized by name
/// on the wire — these helpers own both directions.

/// Derives the per-record [SyncStatus] from the queue subquery counts.
///
/// Priority: a mutation that exhausted its attempts is the most actionable
/// state (failed); an in-flight mutation beats plain pending; anything
/// queued at all beats synced.
SyncStatus deriveSyncStatus({
  required int queueCount,
  required int syncingCount,
  required int failedCount,
}) {
  if (failedCount > 0) return SyncStatus.failed;
  if (syncingCount > 0) return SyncStatus.syncing;
  if (queueCount > 0) return SyncStatus.pending;
  return SyncStatus.synced;
}

/// Converts a stored [EntityType] index, rejecting corrupt values.
EntityType entityTypeFromIndex(int index) {
  if (index < 0 || index >= EntityType.values.length) {
    throw FormatException('Unknown entity type index: $index');
  }
  return EntityType.values[index];
}

/// Converts a stored [MutationType] index, rejecting corrupt values.
MutationType mutationTypeFromIndex(int index) {
  if (index < 0 || index >= MutationType.values.length) {
    throw FormatException('Unknown mutation type index: $index');
  }
  return MutationType.values[index];
}

/// Converts a stored [TaskPriority] index, rejecting corrupt values.
TaskPriority priorityFromIndex(int index) {
  if (index < 0 || index >= TaskPriority.values.length) {
    throw FormatException('Unknown task priority index: $index');
  }
  return TaskPriority.values[index];
}

// ---------------------------------------------------------------------------
// Projects
// ---------------------------------------------------------------------------

/// Maps a domain [Project] to a full upsert companion.
ProjectsCompanion projectToCompanion(Project project) {
  return ProjectsCompanion.insert(
    id: project.id,
    name: project.name,
    colorValue: project.colorValue,
    createdAt: project.createdAt,
    updatedAt: project.updatedAt,
    version: project.version,
    isDeleted: Value(project.isDeleted),
  );
}

/// Maps a typed [ProjectRow] to the domain entity.
Project projectFromRow(ProjectRow row) {
  return Project(
    id: row.id,
    name: row.name,
    colorValue: row.colorValue,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    isDeleted: row.isDeleted,
  );
}

/// Maps one row of `ProjectsDao.watchProjects` (entity columns + the
/// queue-status subqueries) to the domain entity.
Project projectFromQueryRow(QueryRow row) {
  return Project(
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    colorValue: row.read<int>('colorValue'),
    createdAt: row.read<int>('createdAt'),
    updatedAt: row.read<int>('updatedAt'),
    version: row.read<int>('version'),
    isDeleted: row.read<bool>('isDeleted'),
    syncStatus: deriveSyncStatus(
      queueCount: row.read<int>('queueCount'),
      syncingCount: row.read<int>('syncingCount'),
      failedCount: row.read<int>('failedCount'),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

/// Maps a domain [Task] to a full upsert companion.
TasksCompanion taskToCompanion(Task task) {
  return TasksCompanion.insert(
    id: task.id,
    projectId: task.projectId,
    title: task.title,
    notes: Value(task.notes),
    priority: task.priority.index,
    dueDate: Value(task.dueDate),
    isCompleted: Value(task.isCompleted),
    createdAt: task.createdAt,
    updatedAt: task.updatedAt,
    version: task.version,
    isDeleted: Value(task.isDeleted),
  );
}

/// Maps a typed [TaskRow] to the domain entity.
Task taskFromRow(TaskRow row) {
  return Task(
    id: row.id,
    projectId: row.projectId,
    title: row.title,
    notes: row.notes,
    priority: priorityFromIndex(row.priority),
    dueDate: row.dueDate,
    isCompleted: row.isCompleted,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    version: row.version,
    isDeleted: row.isDeleted,
  );
}

/// Maps one row of the task status queries (entity columns + queue-status
/// subqueries) to the domain entity.
Task taskFromQueryRow(QueryRow row) {
  return Task(
    id: row.read<String>('id'),
    projectId: row.read<String>('projectId'),
    title: row.read<String>('title'),
    notes: row.readNullable<String>('notes'),
    priority: priorityFromIndex(row.read<int>('priority')),
    dueDate: row.readNullable<int>('dueDate'),
    isCompleted: row.read<bool>('isCompleted'),
    createdAt: row.read<int>('createdAt'),
    updatedAt: row.read<int>('updatedAt'),
    version: row.read<int>('version'),
    isDeleted: row.read<bool>('isDeleted'),
    syncStatus: deriveSyncStatus(
      queueCount: row.read<int>('queueCount'),
      syncingCount: row.read<int>('syncingCount'),
      failedCount: row.read<int>('failedCount'),
    ),
  );
}

// ---------------------------------------------------------------------------
// Queue mutations
// ---------------------------------------------------------------------------

/// Maps a domain [MutationRecord] to an insert companion.
PendingMutationsCompanion mutationToCompanion(MutationRecord record) {
  return PendingMutationsCompanion.insert(
    mutationId: record.mutationId,
    type: record.type.index,
    entityType: record.entityType.index,
    entityId: record.entityId,
    payloadJson: record.payloadJson,
    baseUpdatedAt: record.baseUpdatedAt,
    baseVersion: record.baseVersion,
    clientTimestamp: record.clientTimestamp,
    queuedAt: record.queuedAt,
    attempts: Value(record.attempts),
    lastError: Value(record.lastError),
    isSyncing: const Value(false),
  );
}

/// Maps a queue row to the domain [MutationRecord].
MutationRecord mutationFromRow(PendingMutationRow row) {
  return MutationRecord(
    mutationId: row.mutationId,
    type: mutationTypeFromIndex(row.type),
    entityType: entityTypeFromIndex(row.entityType),
    entityId: row.entityId,
    payloadJson: row.payloadJson,
    baseUpdatedAt: row.baseUpdatedAt,
    baseVersion: row.baseVersion,
    clientTimestamp: row.clientTimestamp,
    queuedAt: row.queuedAt,
    attempts: row.attempts,
    lastError: row.lastError,
  );
}
