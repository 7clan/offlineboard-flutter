import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/task.dart';
import '../providers/task_editor_provider.dart';
import 'due_date_chip.dart';
import 'priority_chip.dart';
import 'status_icon.dart';

/// One task row: completion checkbox, title, meta chips and sync status.
///
/// Layout contract (accessibility):
///
/// * the checkbox is a 48×48 dp tap area whose semantic label follows the
///   state ("Mark task 'X' as complete" / "… as not complete"),
/// * the title strikes through and dims when completed,
/// * the meta line is a [Wrap], so 2.0× text scale reflows instead of
///   overflowing,
/// * the sync status icon is decorative-in-form but always labeled.
///
/// Business actions go through the task editor controller — the widget never
/// touches repositories.
class TaskListItem extends ConsumerWidget {
  /// Creates the row.
  const TaskListItem({super.key, required this.task, this.onTap});

  /// The task to render.
  final Task task;

  /// Tap handler (opens the task editor).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    void toggle() {
      unawaited(
        ref.read(taskEditorProvider.notifier).toggleCompleted(task.id),
      );
    }

    final checkboxLabel = task.isCompleted
        ? "Mark task '${task.title}' as not complete"
        : "Mark task '${task.title}' as complete";

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Semantics(
              label: checkboxLabel,
              checked: task.isCompleted,
              button: true,
              onTap: toggle,
              child: ExcludeSemantics(
                child: InkWell(
                  onTap: toggle,
                  borderRadius: BorderRadius.circular(24),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: Checkbox(
                        value: task.isCompleted,
                        onChanged: (_) => toggle(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: task.isCompleted
                            ? theme.colorScheme.onSurfaceVariant
                            : null,
                        decoration: task.isCompleted
                            ? TextDecoration.lineThrough
                            : null,
                        decorationColor: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        DueDateChip(
                          dueDate: task.dueDate,
                          isCompleted: task.isCompleted,
                        ),
                        PriorityChip(priority: task.priority),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: SyncStatusIcon(status: task.syncStatus),
            ),
          ],
        ),
      ),
    );
  }
}
