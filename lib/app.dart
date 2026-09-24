import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'presentation/providers/queue_badge_provider.dart';
import 'presentation/providers/sync_controller.dart';

/// Placeholder OfflineBoard app shell.
///
/// Wires the Material 3 theme and proves the whole state layer is alive:
/// the placeholder screen watches the sync controller and the queue badge,
/// which lazily boots the database, the in-process sync server, the sync
/// engine and the connectivity service.
///
/// The presentation wave replaces [_PlaceholderScreen] with the real
/// GoRouter screen setup; this file deliberately contains no business
/// logic.
class OfflineBoardApp extends StatelessWidget {
  /// Creates the app.
  const OfflineBoardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OfflineBoard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const _PlaceholderScreen(),
    );
  }
}

class _PlaceholderScreen extends ConsumerWidget {
  const _PlaceholderScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncControllerProvider);
    final queued = ref.watch(queueBadgeProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('OfflineBoard')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              switch (syncState) {
                SyncIdle() => const Text('Synced — everything is up to date.'),
                SyncSyncing(:final queuedCount) => Text(
                  'Syncing $queuedCount queued changes…',
                ),
                SyncFailed(:final message) => Text(message),
                SyncOffline() => const Text(
                  'Offline — changes are saved locally and will sync '
                  'automatically.',
                ),
              },
              const SizedBox(height: 8),
              Text(
                queued == 0
                    ? 'No queued mutations'
                    : '$queued queued mutations',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 32),
              Text(
                'Offline-first foundation is wired: local database, sync '
                'queue, connectivity and conflict resolution.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'The screens land in the presentation wave.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
