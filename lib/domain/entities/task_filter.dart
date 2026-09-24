import 'task.dart';

/// How the completion filter behaves in the task list.
enum TaskCompletionFilter {
  /// All non-deleted tasks.
  all,

  /// Only incomplete tasks.
  incomplete,

  /// Only completed tasks.
  completed,
}

/// Query/filter state for task lists.
///
/// This single immutable value doubles as
/// * the repository query (drift WHERE clauses) and
/// * the Riverpod filter state (family argument, hence `==`/`hashCode`).
///
/// The notifier debounces [search] updates before committing them here.
class TaskFilter {
  /// Creates a filter.
  const TaskFilter({
    this.projectId,
    this.completion = TaskCompletionFilter.all,
    this.priority,
    this.dueBefore,
    this.search = '',
  });

  /// Restrict to one project, or all projects when `null`.
  final String? projectId;

  /// Completion slice.
  final TaskCompletionFilter completion;

  /// Restrict to one priority, or all when `null`.
  final TaskPriority? priority;

  /// Only tasks due on/before this UTC-millis instant, or all when `null`.
  final int? dueBefore;

  /// Case-insensitive title search (debounced upstream).
  final String search;

  /// The filter matching every non-deleted task.
  static const TaskFilter all = TaskFilter();

  /// Whether any dimension actually narrows the list.
  bool get isFiltering =>
      projectId != null ||
      completion != TaskCompletionFilter.all ||
      priority != null ||
      dueBefore != null ||
      search.trim().isNotEmpty;

  TaskFilter copyWith({
    Object? projectId = _unset,
    TaskCompletionFilter? completion,
    Object? priority = _unset,
    Object? dueBefore = _unset,
    String? search,
  }) {
    return TaskFilter(
      projectId: identical(projectId, _unset)
          ? this.projectId
          : projectId as String?,
      completion: completion ?? this.completion,
      priority: identical(priority, _unset)
          ? this.priority
          : priority as TaskPriority?,
      dueBefore: identical(dueBefore, _unset)
          ? this.dueBefore
          : dueBefore as int?,
      search: search ?? this.search,
    );
  }

  /// Sentinel letting [copyWith] distinguish "not provided" from
  /// "explicitly clear this nullable filter".
  static const _unset = Object();

  @override
  bool operator ==(Object other) {
    return other is TaskFilter &&
        other.projectId == projectId &&
        other.completion == completion &&
        other.priority == priority &&
        other.dueBefore == dueBefore &&
        other.search == search;
  }

  @override
  int get hashCode =>
      Object.hash(projectId, completion, priority, dueBefore, search);

  @override
  String toString() =>
      'TaskFilter(project: $projectId, completion: $completion, '
      'priority: $priority, dueBefore: $dueBefore, search: "$search")';
}
