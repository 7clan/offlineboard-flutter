import '../entities/task.dart';
import '../entities/task_filter.dart';

/// Contract for task persistence (local-first).
///
/// Every mutation writes the local SQLite database inside a single
/// transaction AND enqueues the matching sync-queue entry, so the record is
/// immediately usable while offline. Reads are Drift watch streams that
/// re-emit on every relevant table change. Implementations must translate
/// every low-level error into an [AppException] — raw exceptions never
/// escape this boundary.
abstract interface class TaskRepository {
  /// Watches non-deleted tasks matching [filter], ordered by due date
  /// (nulls last), then priority (urgent first), then title.
  Stream<List<Task>> watchTasks(TaskFilter filter);

  /// Watches a single task (tombstones included), or an empty stream item
  /// (`null`) when the id is unknown.
  Stream<Task?> watchTask(String id);

  /// Fetches a task by id (tombstones included), or `null`.
  Future<Task?> getTaskById(String id);

  /// Creates a task locally and queues a `create` mutation for the server.
  ///
  /// The task is assigned a client id, `version = 1` and timestamps from the
  /// injected clock.
  Future<Task> createTask({
    required String projectId,
    required String title,
    String? notes,
    TaskPriority priority = TaskPriority.medium,
    int? dueDate,
  });

  /// Applies an edit locally and queues an `update` mutation.
  ///
  /// `version` is bumped and `updatedAt` refreshed from the injected clock;
  /// the mutation carries the pre-edit base version so the server can
  /// detect concurrent edits.
  Future<Task> updateTask(Task task);

  /// Marks a task done / not done locally (a special case of [updateTask]).
  Future<Task> setCompleted(String id, bool completed);

  /// Soft-deletes a task (tombstone) and queues a `delete` mutation.
  Future<void> deleteTask(String id);
}
