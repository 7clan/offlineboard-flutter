import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connectivity_provider.dart';

/// Demo-only offline simulation, surfaced by the Settings screen.
///
/// [DemoConnectivityService] wraps a real connectivity source and can force
/// the whole app offline. The sync controller reacts exactly like it does to
/// a genuine connection loss: mutations keep saving locally and the queue
/// drains on "reconnect".
///
/// Production wiring lives in `main.dart`, which overrides
/// `connectivityServiceProvider` with [demoConnectivityProvider] — so the
/// app's connectivity source is always this wrapper. Tests that want to
/// exercise the switch wire the same override in their `ProviderScope` and
/// may stub the platform source:
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     connectivityServiceProvider.overrideWith(
///       (ref) => ref.watch(demoConnectivityProvider),
///     ),
///     platformConnectivityProvider.overrideWithValue(fake),
///   ],
///   child: const OfflineBoardApp(),
/// )
/// ```
///
/// Tests that instead override `connectivityServiceProvider` with their own
/// fake keep full control of connectivity; the Settings switch then drives a
/// detached wrapper and does not interfere.
class DemoConnectivityService extends ConnectivityService {
  /// Creates the wrapper around a connectivity [platform] source.
  DemoConnectivityService({
    required ConnectivityService platform,
    bool initialForcedOffline = false,
  }) : _inner = platform,
       _forcedOffline = initialForcedOffline;

  final ConnectivityService _inner;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  StreamSubscription<bool>? _innerSubscription;
  bool _forcedOffline;

  @override
  bool get isOnline => !_forcedOffline && _inner.isOnline;

  @override
  Stream<bool> get onConnectivityChanged => _changes.stream;

  /// Whether the demo switch currently forces offline mode.
  bool get isForcedOffline => _forcedOffline;

  /// Starts forwarding the wrapped service's changes; call once after
  /// construction (kept out of the constructor so construction stays
  /// synchronous and side-effect free).
  void start() {
    _innerSubscription = _inner.onConnectivityChanged.listen(
      (_) => _emit(),
      onError: (Object error) {
        // A platform-channel hiccup must never break the wrapper; the last
        // known connectivity state simply stays until the next event.
      },
    );
  }

  /// Toggles forced-offline mode and notifies every listener.
  void setForcedOffline(bool value) {
    if (_forcedOffline == value) return;
    _forcedOffline = value;
    _emit();
  }

  /// Stops forwarding changes. The wrapped service's own disposal belongs
  /// to its provider ([platformConnectivityProvider]).
  Future<void> dispose() async {
    await _innerSubscription?.cancel();
    _innerSubscription = null;
    await _changes.close();
  }

  void _emit() {
    if (!_changes.isClosed) {
      _changes.add(isOnline);
    }
  }
}

/// Whether the "Simulate offline (demo)" switch is engaged.
final simulateOfflineProvider =
    NotifierProvider<SimulateOfflineController, bool>(
      SimulateOfflineController.new,
    );

/// Drives the demo offline simulation from the Settings switch.
class SimulateOfflineController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Engages or disengages the simulation.
  ///
  /// The wrapper is poked directly (it is the same instance the sync
  /// controller subscribes to), so the change propagates through
  /// `onConnectivityChanged` without rebuilding any provider.
  Future<void> setForcedOffline(bool value) async {
    if (state == value) return;
    state = value;
    ref.read(demoConnectivityProvider).setForcedOffline(value);
  }
}

/// The platform connectivity source behind the wrapper.
///
/// This is the seam tests override to stay off platform channels while
/// still exercising the demo switch.
final platformConnectivityProvider = Provider<ConnectivityService>((ref) {
  final platform = ConnectivityPlusService();
  unawaited(platform.initialize());
  ref.onDispose(() => unawaited(platform.dispose()));
  return platform;
});

/// The app's connectivity source: the platform service wrapped with the
/// demo offline switch.
final demoConnectivityProvider = Provider<DemoConnectivityService>((ref) {
  final service = DemoConnectivityService(
    platform: ref.watch(platformConnectivityProvider),
    initialForcedOffline: ref.read(simulateOfflineProvider),
  );
  service.start();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
