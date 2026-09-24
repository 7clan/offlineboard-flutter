import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the device currently has a usable network connection, plus a
/// stream of changes.
///
/// This is the only place the app talks to `connectivity_plus` — the sync
/// controller (and tests) only ever see [ConnectivityService]. To fake
/// connectivity in tests, subclass [ConnectivityService] and override the
/// provider:
///
/// ```dart
/// class FakeConnectivityService extends ConnectivityService {
///   FakeConnectivityService(this.online);
///   bool online;
///   final _changes = StreamController<bool>.broadcast();
///   @override
///   bool get isOnline => online;
///   @override
///   Stream<bool> get onConnectivityChanged => _changes.stream;
///   void emit(bool value) { online = value; _changes.add(value); }
/// }
///
/// final fake = FakeConnectivityService(true);
/// // ...
/// connectivityServiceProvider.overrideWithValue(fake),
/// ```
abstract class ConnectivityService {
  /// Constructor for subclasses.
  const ConnectivityService();

  /// Whether the device is online right now.
  ///
  /// Starts optimistic (`true`) until the platform reports — a wrong
  /// optimistic guess only costs one failed sync round, which the engine
  /// retries with backoff.
  bool get isOnline;

  /// Emits the connectivity status whenever it changes.
  ///
  /// The stream is broadcast; listeners may join at any time.
  Stream<bool> get onConnectivityChanged;
}

/// Production [ConnectivityService] on top of `connectivity_plus`.
///
/// Call [initialize] once (the provider does it) to seed [isOnline] with a
/// real platform check and subscribe to platform events; call [dispose] to
/// release the subscription.
class ConnectivityPlusService extends ConnectivityService {
  /// Creates the service around an injectable [Connectivity] instance.
  ConnectivityPlusService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _online = true;

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get onConnectivityChanged => _changes.stream;

  /// Seeds [isOnline] from the platform and starts listening for changes.
  Future<void> initialize() async {
    if (_subscription != null) return;
    try {
      _online = _isOnlineResult(await _connectivity.checkConnectivity());
    } on Object {
      // Platform check failed — stay optimistic; a wrong guess surfaces as
      // a retried sync round rather than a stuck offline badge.
      _online = true;
    }
    _subscription = _connectivity.onConnectivityChanged.listen((results) {
      _online = _isOnlineResult(results);
      _changes.add(_online);
    });
  }

  /// Cancels the platform subscription and closes the stream.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _changes.close();
  }

  /// A result list is offline only when it is empty or explicitly `none`
  /// (`connectivity_plus` guarantees `none` appears alone, never mixed).
  static bool _isOnlineResult(List<ConnectivityResult> results) =>
      results.isNotEmpty && !results.contains(ConnectivityResult.none);
}

/// The app's connectivity source.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityPlusService();
  unawaited(service.initialize());
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
