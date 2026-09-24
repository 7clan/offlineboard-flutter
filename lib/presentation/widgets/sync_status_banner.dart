import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sync_banner_provider.dart';

/// The global sync banner pinned above the tab shell.
///
/// Watches [syncBannerProvider] (which derives from the sync controller and
/// the live queue size):
///
/// * offline — neutral: "Offline — changes are saved locally",
/// * pending — attention: "N changes waiting to sync" + "Sync now",
/// * syncing — progress indicator + count,
/// * failed  — error colors, the mapped user-safe message + "Retry",
/// * synced  — confirmation, shown briefly by the banner controller.
///
/// The message is a live region so state changes are announced. Buttons
/// delegate to the sync controller — no engine access here.
class SyncStatusBanner extends ConsumerWidget {
  /// Creates the banner.
  const SyncStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = ref.watch(syncBannerProvider);
    if (banner.kind == SyncBannerKind.hidden) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final appearance = _appearance(banner, scheme);
    final (:background, :foreground, :icon, :message, :actionLabel) =
        appearance;

    return SafeArea(
      bottom: false,
      child: Material(
        color: background,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(
              children: [
                if (icon != null)
                  Icon(icon, color: foreground)
                else
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: foreground,
                      semanticsLabel: message,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (actionLabel != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: foreground,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _runAction(ref, banner.kind),
                    child: Text(actionLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _runAction(WidgetRef ref, SyncBannerKind kind) {
    final controller = ref.read(syncBannerProvider.notifier);
    unawaited(
      kind == SyncBannerKind.failed ? controller.retry() : controller.syncNow(),
    );
  }

  static ({
    Color background,
    Color foreground,
    IconData? icon,
    String message,
    String? actionLabel,
  }) _appearance(SyncBannerState banner, ColorScheme scheme) {
    final queued = banner.queuedCount;
    final changeWord = queued == 1 ? 'change' : 'changes';
    switch (banner.kind) {
      case SyncBannerKind.hidden:
        return (
          background: scheme.surface,
          foreground: scheme.onSurface,
          icon: null,
          message: '',
          actionLabel: null,
        );
      case SyncBannerKind.offline:
        return (
          background: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
          icon: Icons.wifi_off_outlined,
          message: banner.message ?? 'Offline',
          actionLabel: null,
        );
      case SyncBannerKind.pending:
        return (
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer,
          icon: Icons.cloud_upload_outlined,
          message: '$queued $changeWord waiting to sync',
          actionLabel: 'Sync now',
        );
      case SyncBannerKind.syncing:
        return (
          background: scheme.secondaryContainer,
          foreground: scheme.onSecondaryContainer,
          icon: null,
          message: 'Syncing $queued $changeWord…',
          actionLabel: null,
        );
      case SyncBannerKind.failed:
        return (
          background: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
          icon: Icons.cloud_off_outlined,
          message: banner.message ?? 'Sync failed.',
          actionLabel: 'Retry',
        );
      case SyncBannerKind.synced:
        return (
          background: scheme.primaryContainer,
          foreground: scheme.onPrimaryContainer,
          icon: Icons.cloud_done_outlined,
          message: banner.message ?? 'All changes synced.',
          actionLabel: null,
        );
    }
  }
}
