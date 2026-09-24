import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// OfflineBoard entry point.
///
/// The [ProviderScope] carries the full dependency graph — local database,
/// connectivity service, sync server/client, sync engine, repositories and
/// controllers — initialized lazily on first watch. The placeholder screen
/// in [OfflineBoardApp] watches the sync controller and queue badge, which
/// boots the entire offline-first pipeline on startup.
void main() {
  runApp(const ProviderScope(child: OfflineBoardApp()));
}
