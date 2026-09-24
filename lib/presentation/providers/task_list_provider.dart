import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/task.dart';
import '../../domain/entities/task_filter.dart';
import 'repositories_provider.dart';

/// Live task list for any [TaskFilter] — the family argument is an
/// immutable value with proper `==`, so Riverpod caches one stream per
/// distinct filter and rebuilds only when the filter actually changes.
///
/// Combine with `activeTaskFilterProvider` (task_filters_provider.dart) for
/// the current screen's filter:
///
/// ```dart
/// final tasks = ref.watch(
///   taskListProvider(ref.watch(activeTaskFilterProvider)),
/// );
/// ```
///
/// The stream honors every filter dimension (project, completion,
/// priority, due date, search) in one parameterized SQL query and re-emits
/// with derived per-task [Task.syncStatus] on every relevant change.
final taskListProvider = StreamProvider.family<List<Task>, TaskFilter>((
  ref,
  filter,
) {
  return ref.watch(taskRepositoryProvider).watchTasks(filter);
});
