import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/sync/conflict_resolver.dart';
import '../../domain/sync/sync_engine.dart';
import '../../data/remote/mock_sync_server.dart';
import '../../data/remote/sync_api_client.dart';
import '../../data/sync/conflict_resolver.dart';
import '../../data/sync/sync_engine_impl.dart';
import 'core_providers.dart';
import 'database_provider.dart';

/// The pure last-write-wins conflict strategy.
///
/// Stateless — one shared instance. Tests may override with a stub to force
/// specific resolutions.
final conflictResolverProvider = Provider<ConflictResolver>(
  (ref) => const LastWriteWinsConflictResolver(),
);

/// The in-process sync backend: a real `HttpServer` on 127.0.0.1 holding
/// the server-side dataset (see `MockSyncServer` for the fault-injection
/// toggles).
///
/// Binding happens in [MockSyncServer.start]; the ephemeral port is known
/// only afterwards, which is why this is a [FutureProvider]. Tests that
/// want their own server override this provider.
final syncServerProvider = FutureProvider<MockSyncServer>((ref) async {
  final server = MockSyncServer(clock: ref.watch(clockProvider));
  await server.start();
  ref.onDispose(() => unawaited(server.close()));
  return server;
});

/// The Dio-based sync client, pointed at the in-process server.
final syncApiClientProvider = FutureProvider<SyncApiClient>((ref) async {
  final server = await ref.watch(syncServerProvider.future);
  return SyncApiClient(
    baseUrl: server.baseUrl,
    config: ref.watch(appConfigProvider),
  );
});

/// The app's sync engine.
///
/// While [syncEngineProvider] is loading (server binding), consumers see an
/// `AsyncValue` in the loading state; the `SyncController` kicks the first
/// round as soon as the engine materializes.
final syncEngineProvider = FutureProvider<SyncEngine>((ref) async {
  final client = await ref.watch(syncApiClientProvider.future);
  return SyncEngineImpl(
    db: ref.watch(databaseProvider),
    client: client,
    resolver: ref.watch(conflictResolverProvider),
    clock: ref.watch(clockProvider),
    config: ref.watch(appConfigProvider),
    idGenerator: ref.watch(idGeneratorProvider),
  );
});
