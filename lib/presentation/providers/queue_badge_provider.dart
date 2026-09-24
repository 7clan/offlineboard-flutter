import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';

/// Live number of mutations waiting in the sync queue (pending + syncing +
/// failed) — drives the offline/queue badge in the app bar.
///
/// Re-emits on every queue change; `0` means the local database and the
/// server are in step (as far as the client knows).
final queueBadgeProvider = StreamProvider<int>(
  (ref) => ref.watch(databaseProvider).syncQueueDao.watchCount(),
);
