import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/presentation/providers/connectivity_provider.dart';
import 'package:offlineboard/presentation/providers/demo_connectivity_provider.dart';
import 'package:offlineboard/presentation/providers/sync_controller.dart';
import 'package:offlineboard/presentation/providers/sync_engine_provider.dart';

import '../helpers/fakes.dart';

// The demo offline switch (Settings screen) wraps the platform connectivity
// source in a DemoConnectivityService and forces it offline. These tests
// wire it exactly like main.dart does — connectivityServiceProvider →
// demoConnectivityProvider, platformConnectivityProvider stubbed — and
// prove the sync controller reacts to the switch like a real connection
// loss.

Future<void> settle([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('DemoConnectivityService (unit)', () {
    test('wraps the platform source and forwards its changes', () async {
      final platform = FakeConnectivityService(true);
      final service = DemoConnectivityService(platform: platform);
      addTearDown(service.dispose);
      service.start();
      expect(service.isOnline, isTrue);

      final events = <bool>[];
      final sub = service.onConnectivityChanged.listen(events.add);
      addTearDown(sub.cancel);

      platform.emit(false);
      await settle();
      expect(service.isOnline, isFalse);
      expect(events, [false]);

      platform.emit(true);
      await settle();
      expect(service.isOnline, isTrue);
      expect(events, [false, true]);
    });

    test('forced offline wins over a connected platform', () async {
      final platform = FakeConnectivityService(true);
      final service = DemoConnectivityService(platform: platform);
      addTearDown(service.dispose);
      service.start();

      final events = <bool>[];
      final sub = service.onConnectivityChanged.listen(events.add);
      addTearDown(sub.cancel);

      service.setForcedOffline(true);
      await settle();
      expect(service.isOnline, isFalse);
      expect(service.isForcedOffline, isTrue);
      expect(events, [false]);

      // A platform event while forced stays offline — the switch wins.
      // (The wrapper forwards platform events verbatim; a duplicate
      // same-value event is harmless because listeners are idempotent.)
      platform.emit(false);
      await settle();
      expect(service.isOnline, isFalse);
      expect(events, [false, false]);

      // Platform recovers while still forced — still offline.
      platform.emit(true);
      await settle();
      expect(service.isOnline, isFalse);
      expect(events, [false, false, false]);

      // Releasing the switch returns to the (now online) platform state.
      service.setForcedOffline(false);
      await settle();
      expect(service.isOnline, isTrue);
      expect(events, [false, false, false, true]);
    });

    test('setForcedOffline with the same value emits nothing', () async {
      final platform = FakeConnectivityService(true);
      final service = DemoConnectivityService(
        platform: platform,
        initialForcedOffline: true,
      );
      addTearDown(service.dispose);
      service.start();

      final events = <bool>[];
      final sub = service.onConnectivityChanged.listen(events.add);
      addTearDown(sub.cancel);

      service.setForcedOffline(true);
      await settle();
      expect(events, isEmpty, reason: 'no change, no event');
    });
  });

  group('wired like main.dart (providers)', () {
    test(
      'the Settings switch drives the sync controller offline and back',
      () async {
        final platform = FakeConnectivityService(true);
        final container = ProviderContainer(
          overrides: [
            platformConnectivityProvider.overrideWithValue(platform),
            connectivityServiceProvider.overrideWith(
              (ref) => ref.watch(demoConnectivityProvider),
            ),
            syncEngineProvider.overrideWith((ref) async => FakeSyncEngine()),
          ],
        );
        addTearDown(container.dispose);
        container.listen(syncControllerProvider, (_, _) {});

        await settle();
        expect(container.read(syncControllerProvider), isA<SyncIdle>());
        expect(container.read(connectivityServiceProvider).isOnline, isTrue);

        // Flip the Settings switch.
        await container
            .read(simulateOfflineProvider.notifier)
            .setForcedOffline(true);
        await settle();
        expect(container.read(simulateOfflineProvider), isTrue);
        expect(container.read(connectivityServiceProvider).isOnline, isFalse);
        expect(
          container.read(syncControllerProvider),
          isA<SyncOffline>(),
          reason:
              'the controller sees the simulated loss exactly like a '
              'real one',
        );

        // Release the switch — connectivity (and syncing) returns.
        await container
            .read(simulateOfflineProvider.notifier)
            .setForcedOffline(false);
        await settle();
        expect(container.read(connectivityServiceProvider).isOnline, isTrue);
        expect(container.read(syncControllerProvider), isA<SyncIdle>());
      },
    );
  });
}
