import 'package:flutter/material.dart';

/// Full-area empty state.
///
/// Every list screen names *what is missing* and what the user can do about
/// it — an empty screen must never look broken. Purely presentational: no
/// state, no side effects.
class EmptyView extends StatelessWidget {
  /// Creates the empty state.
  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  /// Icon hinting at the missing content.
  final IconData icon;

  /// Short headline, e.g. "No projects yet".
  final String title;

  /// One or two sentences of guidance.
  final String message;

  /// Optional call-to-action label.
  final String? actionLabel;

  /// Optional call-to-action handler.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 36,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: onAction,
                icon: const Icon(Icons.add),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
