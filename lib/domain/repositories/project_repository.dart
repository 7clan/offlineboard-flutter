import '../entities/project.dart';

/// Contract for project persistence (local-first).
///
/// Same rules as `TaskRepository`: single-transaction local write + sync
/// queue entry; watch streams for reads; mapped [AppException]s only.
abstract interface class ProjectRepository {
  /// Watches non-deleted projects ordered by name.
  Stream<List<Project>> watchProjects();

  /// Watches a single project (tombstones included), or `null` when the id
  /// is unknown.
  Stream<Project?> watchProject(String id);

  /// Fetches a project by id (tombstones included), or `null`.
  Future<Project?> getProjectById(String id);

  /// Creates a project locally and queues a `create` mutation.
  Future<Project> createProject({
    required String name,
    required int colorValue,
  });

  /// Applies an edit locally and queues an `update` mutation.
  Future<Project> updateProject(Project project);

  /// Soft-deletes a project (tombstone) and queues a `delete` mutation.
  ///
  /// Deleting a project also tombstones all of its non-deleted tasks in the
  /// same transaction, each with its own queued `delete` mutation — the
  /// cascade must reach the server for every child row.
  Future<void> deleteProject(String id);
}
