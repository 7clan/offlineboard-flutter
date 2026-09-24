import 'package:flutter/material.dart';

/// Full-area error state with retry — the standard "something went wrong"
/// surface for list screens.
///
/// Callers pass a *mapped* message (`AppException.userMessage` from the
/// provider layer); raw exceptions never reach this widget.
class ErrorView extends StatelessWidget {
  /// Creates the error state.
  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.title = 'Something went wrong',
  });

  /// User-safe error description.
  final String message;

  /// Headline above the message.
  final String title;

  /// Retry handler (usually `ref.invalidate` of the failed provider).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 56,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
