import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/task.dart';
import '../../domain/entities/task_filter.dart';
import 'task_list_provider.dart';

/// Per-project task counts used by the projects list and the project
/// detail header.
class ProjectStats {
  /// Creates the counters.
  const ProjectStats({required this.total, required this.completed});

  /// Total non-deleted tasks of the project.
  final int total;

  /// How many of them are completed.
  final int completed;

  /// How many are still open.
  int get remaining => total - completed;

  /// Progress in `[0, 1]` — `0` when the project has no tasks.
  double get progress => total == 0 ? 0 : completed / total;

  /// The empty counters.
  static const ProjectStats empty = ProjectStats(total: 0, completed: 0);
}

/// Live per-project task counts.
///
/// Derives from a single watch of every non-deleted task, so project cards
/// and detail headers update together with the task list without extra
/// database streams.
final projectStatsProvider = Provider<Map<String, ProjectStats>>((ref) {
  final tasks =
      ref.watch(taskListProvider(TaskFilter.all)).value ?? const <Task>[];
  final stats = <String, ProjectStats>{};
  for (final task in tasks) {
    final current = stats[task.projectId] ?? ProjectStats.empty;
    stats[task.projectId] = ProjectStats(
      total: current.total + 1,
      completed: current.completed + (task.isCompleted ? 1 : 0),
    );
  }
  return stats;
});
