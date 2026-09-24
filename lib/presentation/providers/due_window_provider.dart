import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/clock.dart';
import '../../domain/entities/task_filter.dart';
import 'core_providers.dart';
import 'task_filters_provider.dart';

/// The due-date window shown by the task filter bar.
enum DueWindow {
  /// Every task, regardless of due date.
  any('Any due date'),

  /// Due today or earlier.
  today('Due today'),

  /// Due within the next seven days.
  thisWeek('Due this week'),

  /// Due before today (and still incomplete when combined with the
  /// completion filter).
  overdue('Overdue');

  const DueWindow(this.label);

  /// User-facing chip label.
  final String label;
}

/// The selected due window of the task filter bar.
final dueWindowProvider = NotifierProvider<DueWindowController, DueWindow>(
  DueWindowController.new,
);

/// Controls the due-window chip row.
class DueWindowController extends Notifier<DueWindow> {
  @override
  DueWindow build() => DueWindow.any;

  /// Selects a window.
  void setWindow(DueWindow window) {
    if (state == window) return;
    state = window;
  }

  /// Resets every filter dimension — the due window and the shared filter
  /// state (completion, priority, committed search).
  void clearAll() {
    ref.read(taskFilterStateProvider.notifier).clear();
    state = DueWindow.any;
  }
}

/// The upper due-date bound (UTC millis) for [window], or `null` when the
/// window is unbounded.
///
/// "Overdue" is expressed as "due before the start of today" so it composes
/// with the completion chips (e.g. completed-but-late tasks).
int? dueWindowCutoff(DueWindow window, Clock clock) {
  final now = clock().toLocal();
  final startOfToday = DateTime(now.year, now.month, now.day);
  switch (window) {
    case DueWindow.any:
      return null;
    case DueWindow.today:
      return startOfToday.add(const Duration(days: 1)).millisecondsSinceEpoch -
          1;
    case DueWindow.thisWeek:
      return startOfToday.add(const Duration(days: 7)).millisecondsSinceEpoch -
          1;
    case DueWindow.overdue:
      return startOfToday.millisecondsSinceEpoch - 1;
  }
}

/// The effective task query: the shared filter state with the due window
/// mapped onto its `dueBefore` dimension.
///
/// The tasks screen and every project detail page watch this provider (the
/// project dimension is pinned by the caller via `TaskFilter.copyWith`),
/// so both surfaces share one filter bar with consistent behavior.
final effectiveTaskFilterProvider = Provider<TaskFilter>((ref) {
  final window = ref.watch(dueWindowProvider);
  return ref
      .watch(taskFilterStateProvider)
      .toTaskFilter()
      .copyWith(dueBefore: dueWindowCutoff(window, ref.watch(clockProvider)));
});
