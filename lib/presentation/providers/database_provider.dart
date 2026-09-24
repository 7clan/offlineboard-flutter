import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/db/app_database.dart';

/// The local source of truth: a Drift/SQLite database.
///
/// Production opens a lazily-initialized file in the app documents directory
/// (the heavy work runs on a background isolate via
/// `NativeDatabase.createInBackground`). Tests swap this provider for an
/// in-memory database — the entire provider graph (repositories, sync
/// engine, queue badge) inherits the override automatically because
/// everything watches it:
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     databaseProvider.overrideWith(
///       (ref) => AppDatabase(NativeDatabase.memory()),
///     ),
///   ],
///   child: const OfflineBoardApp(),
/// )
/// ```
///
/// Remember to close test databases in `tearDown` when constructing them
/// by hand.
final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(_openConnection());
  ref.onDispose(() => unawaited(db.close()));
  return db;
});

/// Opens the SQLite file from the app documents directory.
///
/// [LazyDatabase] defers the (asynchronous) directory lookup to the first
/// query, which keeps the provider itself synchronous.
LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    // Every supported app platform uses '/' as the path separator.
    final file = File('${dir.path}/offlineboard.db');
    return NativeDatabase.createInBackground(file);
  });
}
