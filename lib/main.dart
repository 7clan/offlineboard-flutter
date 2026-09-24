import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'presentation/providers/connectivity_provider.dart';
import 'presentation/providers/demo_connectivity_provider.dart';

/// OfflineBoard entry point.
///
/// The [ProviderScope] carries the full dependency graph — local database,
/// connectivity service, sync server/client, sync engine, repositories and
/// controllers — initialized lazily on first watch. The home shell's sync
/// banner watches the sync controller, which boots the entire offline-first
/// pipeline on startup.
///
/// The production connectivity source is the demo wrapper
/// ([demoConnectivityProvider]): the platform service with the Settings
/// screen's "Simulate offline" switch layered on top. Tests keep the freedom
/// to override `connectivityServiceProvider` with their own fake.
void main() {
  runApp(
    ProviderScope(
      overrides: [
        connectivityServiceProvider.overrideWith(
          (ref) => ref.watch(demoConnectivityProvider),
        ),
      ],
      child: const OfflineBoardApp(),
    ),
  );
}
