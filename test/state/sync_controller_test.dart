import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/core/errors/app_exception.dart';
import 'package:offlineboard/presentation/providers/repositories_provider.dart';
import 'package:offlineboard/presentation/providers/sync_controller.dart';
import 'package:offlineboard/presentation/providers/sync_engine_provider.dart';

import '../helpers/fakes.dart';

// State tests drive the real Riverpod notifiers over fakes (a scriptable
// engine + connectivity) and an in-memory drift database. One test also
// wires the REAL engine + real in-process server (plain test() = real
// zone, real sockets) to prove the reconnect path actually drains.

/// Lets the container settle (provider builds, initial sync kick, streams).
Future<void> settle([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('SyncController state machine (fake engine)', () {
    test(
      'online + clean engine → settles into idle after initial round',
      () async {
        final engine = FakeSyncEngine();
        final connectivity = FakeConnectivityService(true);
        final container = stateTestContainer(
          engine: engine,
          connectivity: connectivity,
        );
        // Keep the controller alive so dependency changes (the engine
        // materializing) rebuild it.
        container.listen(syncControllerProvider, (_, _) {});

        await settle();

        expect(container.read(syncControllerProvider), isA<SyncIdle>());
        expect(engine.syncNowCalls, 1, reason: 'exactly one initial round');
      },
    );

    test('offline start → SyncOffline, rounds are suppressed', () async {
      final engine = FakeSyncEngine();
      final connectivity = FakeConnectivityService(false);
      final container = stateTestContainer(
        engine: engine,
        connectivity: connectivity,
      );
      // Keep the controller alive so dependency changes (the engine
      // materializing) rebuild it.
      container.listen(syncControllerProvider, (_, _) {});

      await settle();

      expect(container.read(syncControllerProvider), isA<SyncOffline>());
      // The initial round was suppressed — no engine call while offline.
      expect(engine.syncNowCalls, 0);

      await container.read(syncControllerProvider.notifier).syncNow();
      expect(engine.syncNowCalls, 0, reason: 'still offline, still no round');
      expect(container.read(syncControllerProvider), isA<SyncOffline>());
    });

    test('offline → syncing → idle across a reconnect drain', () async {
      final engine = FakeSyncEngine(queuedMutationCountValue: 2);
      final connectivity = FakeConnectivityService(false);
      final container = stateTestContainer(
        engine: engine,
        connectivity: connectivity,
      );
      container.listen(syncControllerProvider, (_, _) {});
      await settle();
      expect(container.read(syncControllerProvider), isA<SyncOffline>());

      // Reconnect: the controller must drain immediately.
      engine.syncNowGate = Completer<void>();
      connectivity.emit(true);

      await settle();
      expect(
        container.read(syncControllerProvider),
        isA<SyncSyncing>(),
        reason: 'the drain round is in flight',
      );
      final syncing = container.read(syncControllerProvider) as SyncSyncing;
      expect(syncing.queuedCount, 2);

      engine.syncNowGate!.complete();
      await settle();
      expect(container.read(syncControllerProvider), isA<SyncIdle>());
      expect(engine.syncNowCalls, 1, reason: 'the reconnect drain round');
    });

    test('a failing round surfaces SyncFailed with the mapped message, '
        'then auto-retries and recovers', () async {
      final engine = FakeSyncEngine(
        syncNowOutcome: failedOutcome(
          const NetworkException(),
          retryAfter: const Duration(milliseconds: 20),
        ),
      );
      final connectivity = FakeConnectivityService(true);
      final container = stateTestContainer(
        engine: engine,
        connectivity: connectivity,
      );
      container.listen(syncControllerProvider, (_, _) {});
      await settle();

      final failed = container.read(syncControllerProvider);
      expect(failed, isA<SyncFailed>());
      expect(
        (failed as SyncFailed).message,
        'You appear to be offline. Changes are saved locally and will sync '
        'when you reconnect.',
      );

      // The backoff timer fires and the (now clean) round recovers.
      engine.syncNowOutcome = null;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await settle();
      expect(container.read(syncControllerProvider), isA<SyncIdle>());
      expect(engine.syncNowCalls, greaterThanOrEqualTo(2));
    });

    test(
      'going offline mid-life switches the state without extra rounds',
      () async {
        final engine = FakeSyncEngine();
        final connectivity = FakeConnectivityService(true);
        final container = stateTestContainer(
          engine: engine,
          connectivity: connectivity,
        );
        container.listen(syncControllerProvider, (_, _) {});
        await settle();
        expect(engine.syncNowCalls, 1);

        connectivity.emit(false);
        await settle();
        expect(container.read(syncControllerProvider), isA<SyncOffline>());
        expect(engine.syncNowCalls, 1, reason: 'no round while offline');
      },
    );

    test('retryFailed delegates to the engine and reports failures', () async {
      final engine = FakeSyncEngine(
        retryFailedOutcome: failedOutcome(
          const ServerException(statusCode: 500),
        ),
      );
      final connectivity = FakeConnectivityService(true);
      final container = stateTestContainer(
        engine: engine,
        connectivity: connectivity,
      );
      container.listen(syncControllerProvider, (_, _) {});
      await settle();

      await container.read(syncControllerProvider.notifier).retryFailed();
      await settle();

      expect(engine.retryFailedCalls, 1);
      expect(container.read(syncControllerProvider), isA<SyncFailed>());
      expect(
        (container.read(syncControllerProvider) as SyncFailed).message,
        'Something went wrong on our side. Please try again.',
      );
    });
  });

  group('SyncController over the REAL engine + server', () {
    test(
      'reconnect drains the queue for real (offline-first repositories)',
      () async {
        // Real drift memory db, real in-process HTTP server, real engine —
        // only connectivity is faked. Plain test() keeps us in the real
        // async zone (see the A-3 lesson), so real sockets work.
        final connectivity = FakeConnectivityService(false);
        final clock = MutablePinnedClock();
        final container = stateTestContainer(
          connectivity: connectivity,
          clock: clock,
        );
        // No engine override: the real provider chain starts the server.
        // Keep a subscription so the controller exists.
        container.listen(syncControllerProvider, (_, _) {});
        await settle();
        expect(container.read(syncControllerProvider), isA<SyncOffline>());

        // Queue local mutations while "offline".
        final projects = container.read(projectRepositoryProvider);
        final tasksRepo = container.read(taskRepositoryProvider);
        final project = await projects.createProject(name: 'P', colorValue: 1);
        clock.advance(const Duration(minutes: 1));
        await tasksRepo.createTask(
          projectId: project.id,
          title: 'Offline task',
        );

        // The repositories fired their fire-and-forget triggers, but the
        // controller must have suppressed every round while offline.
        final engine = await container.read(syncEngineProvider.future);
        final queued = await engine.queuedMutationCount();
        expect(queued, 2);

        // Reconnect → the controller drains → the server converges.
        connectivity.emit(true);
        final drained = await _until(
          () async => await engine.queuedMutationCount() == 0,
        );
        expect(drained, isTrue, reason: 'the queue drained after reconnect');
        await settle();

        final server = await container.read(syncServerProvider.future);
        expect(server.projects.containsKey(project.id), isTrue);
        expect(
          server.tasks.values.any((task) => task['title'] == 'Offline task'),
          isTrue,
        );
        expect(container.read(syncControllerProvider), isA<SyncIdle>());
      },
    );
  });
}

/// Polls [condition] until it holds or [timeout] passes.
Future<bool> _until(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
}
