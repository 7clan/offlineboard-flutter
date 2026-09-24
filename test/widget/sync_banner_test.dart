import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/core/errors/app_exception.dart';
import 'package:offlineboard/presentation/providers/connectivity_provider.dart';
import 'package:offlineboard/presentation/providers/queue_badge_provider.dart';
import 'package:offlineboard/presentation/providers/sync_engine_provider.dart';
import 'package:offlineboard/presentation/widgets/sync_status_banner.dart';

import '../helpers/fakes.dart';

// The sync banner derives everything from the sync controller state plus
// the live queue count. These tests drive the REAL controller over a
// scriptable engine and connectivity fake (no platform channels, no
// sockets) and pin the banner's appearance, actions and the 3s
// auto-dismiss of the "synced" confirmation.
//
// Never pumpAndSettle here: the syncing/pending variants carry progress
// indicators, which animate forever.

void main() {
  late FakeSyncEngine engine;
  late FakeConnectivityService connectivity;
  int queueCount = 0;

  Future<void> pumpBanner(WidgetTester tester) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectivityServiceProvider.overrideWithValue(connectivity),
          syncEngineProvider.overrideWith((ref) async => engine),
          queueBadgeProvider.overrideWith((ref) => Stream.value(queueCount)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: Column(children: [SyncStatusBanner()])),
        ),
      ),
    );
  }

  /// A few frames of fake time — enough for the engine to materialize and
  /// one round to run to completion.
  Future<void> settle(WidgetTester tester, [int frames = 4]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() {
    engine = FakeSyncEngine();
    connectivity = FakeConnectivityService(true);
    queueCount = 0;
  });

  testWidgets('offline state shows the offline banner, no actions', (
    tester,
  ) async {
    connectivity = FakeConnectivityService(false);
    await pumpBanner(tester);
    await settle(tester);

    expect(
      find.textContaining('Offline — changes are saved locally'),
      findsOneWidget,
    );
    expect(find.text('Sync now'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('queued mutations while idle show the pending count + action', (
    tester,
  ) async {
    queueCount = 2;
    await pumpBanner(tester);
    await settle(tester);

    expect(find.text('2 changes waiting to sync'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    final initialRounds = engine.syncNowCalls;

    await tester.tap(find.text('Sync now'));
    await settle(tester);

    expect(engine.syncNowCalls, initialRounds + 1);
    expect(find.text('2 changes waiting to sync'), findsOneWidget);
  });

  testWidgets('a failed round shows the mapped message and a Retry that calls '
      'the engine', (tester) async {
    engine.syncNowOutcome = failedOutcome(const NetworkException());
    await pumpBanner(tester);
    await settle(tester);

    expect(
      find.textContaining('You appear to be offline'),
      findsOneWidget,
      reason: 'the mapped, user-safe message',
    );
    expect(find.text('Retry'), findsOneWidget);

    // Manual retry succeeds → the banner confirms and auto-hides.
    engine.retryFailedOutcome = null;
    await tester.tap(find.text('Retry'));
    await settle(tester);

    expect(engine.retryFailedCalls, 1);
    expect(find.text('All changes synced.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('All changes synced.'), findsNothing);
  });

  testWidgets('syncing shows progress, then the synced flash auto-hides after '
      '3 seconds', (tester) async {
    // Hold the initial round open so the syncing state is observable.
    engine.syncNowGate = Completer<void>();
    await pumpBanner(tester);
    await settle(tester);
    expect(find.text('Syncing…'), findsOneWidget);
    expect(find.text('All changes synced.'), findsNothing);

    engine.syncNowGate!.complete();
    await settle(tester);
    expect(find.text('All changes synced.'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('All changes synced.'), findsNothing);
  });
}
