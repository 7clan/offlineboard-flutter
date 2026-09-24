import 'package:flutter/material.dart';

import '../../domain/entities/sync_enums.dart';

/// Icon + color + semantic label for a record's [SyncStatus].
///
/// Used next to every project and task row so the queue state is always
/// visible:
///
/// * `synced`  — cloud with check, primary (green),
/// * `pending` — cloud with up arrow, tertiary,
/// * `syncing` — small progress indicator,
/// * `failed`  — crossed-out cloud, error.
///
/// The icon is informative, never interactive, so it does not need a
/// 48 dp target — but it is its own semantics boundary and always carries
/// exactly one label.
class SyncStatusIcon extends StatelessWidget {
  /// Creates the status icon.
  const SyncStatusIcon({super.key, required this.status, this.size = 20});

  /// The status to visualize.
  final SyncStatus status;

  /// Icon size (the progress indicator uses the same box).
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (:icon, :color, :label) = _resolve(scheme);
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: icon == null
              ? CircularProgressIndicator(strokeWidth: 2.4, color: color)
              : Icon(icon, size: size, color: color),
        ),
      ),
    );
  }

  ({IconData? icon, Color color, String label}) _resolve(ColorScheme scheme) {
    switch (status) {
      case SyncStatus.synced:
        return (
          icon: Icons.cloud_done_outlined,
          color: scheme.primary,
          label: 'Synced',
        );
      case SyncStatus.pending:
        return (
          icon: Icons.cloud_upload_outlined,
          color: scheme.tertiary,
          label: 'Waiting to sync',
        );
      case SyncStatus.syncing:
        return (icon: null, color: scheme.tertiary, label: 'Syncing');
      case SyncStatus.failed:
        return (
          icon: Icons.cloud_off_outlined,
          color: scheme.error,
          label: 'Sync failed — will retry',
        );
    }
  }
}
