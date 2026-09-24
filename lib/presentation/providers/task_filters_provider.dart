import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/debouncer.dart';
import '../../domain/entities/task.dart';
import '../../domain/entities/task_filter.dart';

/// The task list's filter bar state (one immutable value for every filter
/// dimension).
///
/// [search] holds the *committed* (debounced) search text; the raw
/// keystrokes live in the text field until the debounce fires, keeping the
/// database stream pipeline from thrashing on every character.
class TaskFilterState {
  /// Creates the state.
  const TaskFilterState({
    this.projectId,
    this.completion = TaskCompletionFilter.all,
    this.priority,
    this.dueBefore,
    this.search = '',
  });

  /// Restrict to one project, or all when `null`.
  final String? projectId;

  /// Completion slice.
  final TaskCompletionFilter completion;

  /// Restrict to one priority, or all when `null`.
  final TaskPriority? priority;

  /// Only tasks due on/before this UTC-millis instant, or all when `null`.
  final int? dueBefore;

  /// Committed (debounced) case-insensitive title search.
  final String search;

  /// The state matching every task.
  static const TaskFilterState empty = TaskFilterState();

  /// Whether any dimension actually narrows the list.
  bool get isFiltering =>
      projectId != null ||
      completion != TaskCompletionFilter.all ||
      priority != null ||
      dueBefore != null ||
      search.trim().isNotEmpty;

  /// The domain query for [taskListProvider].
  TaskFilter toTaskFilter() => TaskFilter(
    projectId: projectId,
    completion: completion,
    priority: priority,
    dueBefore: dueBefore,
    search: search,
  );

  /// Sentinel distinguishing "field not provided" from "clear this field"
  /// for the nullable dimensions.
  static const _unset = Object();

  /// Returns a copy with the given fields replaced; passing `null` to the
  /// nullable dimensions clears them.
  TaskFilterState copyWith({
    Object? projectId = _unset,
    TaskCompletionFilter? completion,
    Object? priority = _unset,
    Object? dueBefore = _unset,
    String? search,
  }) {
    return TaskFilterState(
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

  @override
  bool operator ==(Object other) {
    return other is TaskFilterState &&
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
      'TaskFilterState(project: $projectId, completion: $completion, '
      'priority: $priority, dueBefore: $dueBefore, search: "$search")';
}

/// The filter bar controller: setters for every dimension plus a debounced
/// search commit.
final taskFilterStateProvider =
    NotifierProvider<TaskFilterController, TaskFilterState>(
      TaskFilterController.new,
    );

/// The [taskFilterStateProvider] notifier.
class TaskFilterController extends Notifier<TaskFilterState> {
  final Debouncer _searchDebouncer = Debouncer();

  @override
  TaskFilterState build() {
    ref.onDispose(_searchDebouncer.dispose);
    return TaskFilterState.empty;
  }

  /// Restricts to one project (`null` = all projects).
  void setProject(String? projectId) {
    state = state.copyWith(projectId: projectId);
  }

  /// Sets the completion slice.
  void setCompletion(TaskCompletionFilter completion) {
    state = state.copyWith(completion: completion);
  }

  /// Restricts to one priority (`null` = all priorities).
  void setPriority(TaskPriority? priority) {
    state = state.copyWith(priority: priority);
  }

  /// Restricts to tasks due on/before [millis] (`null` = no due filter).
  void setDueBefore(int? millis) {
    state = state.copyWith(dueBefore: millis);
  }

  /// Search-field input — debounced (350 ms of silence) before committing
  /// to the state, so the list query runs once per pause, not per
  /// keystroke.
  void onSearchChanged(String text) {
    _searchDebouncer(() {
      if (state.search != text) {
        state = state.copyWith(search: text);
      }
    });
  }

  /// Commits the search text immediately (tests, or clearing the field).
  void setSearch(String text) {
    _searchDebouncer.cancel();
    if (state.search != text) {
      state = state.copyWith(search: text);
    }
  }

  /// Resets every dimension.
  void clear() {
    _searchDebouncer.cancel();
    state = TaskFilterState.empty;
  }
}

/// The domain filter derived from the current filter state — feed it to
/// `taskListProvider` to get the live, filtered task list.
final activeTaskFilterProvider = Provider<TaskFilter>(
  (ref) => ref.watch(taskFilterStateProvider).toTaskFilter(),
);
