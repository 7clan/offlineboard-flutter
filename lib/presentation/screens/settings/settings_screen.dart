import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/demo_connectivity_provider.dart';
import '../../providers/queue_badge_provider.dart';
import '../../providers/sync_banner_provider.dart';
import '../../providers/sync_controller.dart';

/// Settings: sync controls, the demo offline simulation and about.
///
/// All actions go through the sync controller / simulation notifier — no
/// engine, database or repository access from this widget.
class SettingsScreen extends ConsumerWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final syncState = ref.watch(syncControllerProvider);
    final queued = ref.watch(
      queueBadgeProvider.select((value) => value.value ?? 0),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const _SectionHeader(title: 'Sync'),
          _SyncCard(syncState: syncState, queued: queued),
          const SizedBox(height: 24),
          const _SectionHeader(title: 'Offline'),
          const _OfflineSimulationCard(),
          const SizedBox(height: 24),
          const _SectionHeader(title: 'About'),
          const _AboutCard(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SyncCard extends ConsumerWidget {
  const _SyncCard({required this.syncState, required this.queued});

  final SyncState syncState;
  final int queued;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (:icon, :status) = _statusSummary(syncState);
    final statusColor = switch (syncState) {
      SyncFailed() => scheme.error,
      SyncOffline() => scheme.onSurfaceVariant,
      _ => scheme.primary,
    };
    final isSyncing = syncState is SyncSyncing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Semantics(
                  label: status,
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: icon == null
                        ? CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: statusColor,
                            semanticsLabel: status,
                          )
                        : Icon(icon, color: statusColor, size: 24),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(status, style: theme.textTheme.titleSmall),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              queued == 0
                  ? 'No changes waiting to sync.'
                  : '$queued change(s) waiting in the sync queue.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: isSyncing
                  ? null
                  : () => unawaited(
                      ref.read(syncBannerProvider.notifier).syncNow(),
                    ),
              icon: const Icon(Icons.sync),
              label: const Text('Sync now'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => unawaited(
                ref.read(syncBannerProvider.notifier).retry(),
              ),
              icon: const Icon(Icons.replay),
              label: const Text('Retry failed changes'),
            ),
            const SizedBox(height: 8),
            Text(
              'Changes that stopped syncing after repeated failures stay '
              'queued until retried — retry requeues them and pushes again.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static ({IconData? icon, String status}) _statusSummary(SyncState state) {
    switch (state) {
      case SyncIdle():
        return (icon: Icons.cloud_done_outlined, status: 'All changes synced');
      case SyncSyncing(:final queuedCount):
        final changeWord = queuedCount == 1 ? 'change' : 'changes';
        return (
          icon: null,
          status: 'Syncing $queuedCount $changeWord…',
        );
      case SyncFailed(:final message):
        return (icon: Icons.cloud_off_outlined, status: message);
      case SyncOffline():
        return (
          icon: Icons.wifi_off_outlined,
          status: 'Offline — changes are saved locally',
        );
    }
  }
}

/// The demo offline simulation: drives the app's connectivity wrapper, so
/// the sync controller behaves exactly as with a real connection loss.
class _OfflineSimulationCard extends ConsumerWidget {
  const _OfflineSimulationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final simulatedOffline = ref.watch(simulateOfflineProvider);
    return Card(
      child: SwitchListTile(
        title: const Text('Simulate offline (demo)'),
        subtitle: Text(
          'Pretend the device is offline: changes keep saving locally and '
          'sync when you switch this back off.',
          style: theme.textTheme.bodySmall,
        ),
        value: simulatedOffline,
        onChanged: (value) => unawaited(
          ref.read(simulateOfflineProvider.notifier).setForcedOffline(value),
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.offline_bolt_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  'OfflineBoard',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Version 1.0.0',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'An offline-first project and task manager. Everything you do '
              'is written to a local database first and queued for the sync '
              'server; conflicts resolve with last-write-wins, and your '
              'board stays fully usable without a connection.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
