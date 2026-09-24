import 'package:flutter/material.dart';

import '../../core/utils/formatters.dart';

/// Compact due-date chip for task rows.
///
/// Shows the relative due label ("Today", "In 3 days", "5 days overdue").
/// Overdue incomplete tasks switch to the error container pair so they read
/// at a glance; completed tasks dim to the neutral variant.
class DueDateChip extends StatelessWidget {
  /// Creates the chip.
  const DueDateChip({super.key, required this.dueDate, this.isCompleted = false});

  /// The task's due date (UTC millis), or `null` for none (nothing is
  /// shown).
  final int? dueDate;

  /// Whether the owning task is completed (completed tasks are never
  /// "overdue").
  final bool isCompleted;

  /// Whether [dueDate] falls before the start of [now]'s day and the task
  /// is still incomplete.
  ///
  /// Exposed as a pure, testable function; [now] defaults to the real wall
  /// clock because the chip is rebuilt with every list emission.
  static bool isOverdue(
    int? dueDate, {
    required bool isCompleted,
    DateTime? now,
  }) {
    if (dueDate == null || isCompleted) return false;
    final reference = (now ?? DateTime.now());
    final startOfToday = DateTime(reference.year, reference.month, reference.day);
    final due = DateTime.fromMillisecondsSinceEpoch(dueDate).toLocal();
    final dueDay = DateTime(due.year, due.month, due.day);
    return dueDay.isBefore(startOfToday);
  }

  @override
  Widget build(BuildContext context) {
    if (dueDate == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final overdue = isOverdue(
      dueDate,
      isCompleted: isCompleted,
    );
    final label = AppFormatters.dueDateRelative(dueDate);
    final background = overdue
        ? theme.colorScheme.errorContainer
        : isCompleted
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.secondaryContainer;
    final foreground = overdue
        ? theme.colorScheme.onErrorContainer
        : isCompleted
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSecondaryContainer;
    return Semantics(
      label: 'Due $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 14, color: foreground),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
