import 'package:flutter/material.dart';

import '../../domain/entities/task.dart';

/// Compact priority indicator for task rows.
///
/// Color roles stay inside the theme (no ad-hoc palette):
///
/// * `low`    — neutral surface container,
/// * `medium` — secondary container,
/// * `high`   — tertiary container,
/// * `urgent` — error container.
class PriorityChip extends StatelessWidget {
  /// Creates the chip.
  const PriorityChip({super.key, required this.priority, this.compact = false});

  /// The priority to visualize.
  final TaskPriority priority;

  /// Whether to show the icon without the label (dense rows).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (background, foreground) = switch (priority) {
      TaskPriority.low => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      TaskPriority.medium => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      TaskPriority.high => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      TaskPriority.urgent => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Semantics(
      // Own boundary with one label — without it the chip's custom label
      // and its inner text both merge into the row (duplicated readings).
      container: true,
      label: 'Priority: ${priority.label}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag_outlined, size: 14, color: foreground),
              if (!compact) ...[
                const SizedBox(width: 4),
                Text(
                  priority.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
