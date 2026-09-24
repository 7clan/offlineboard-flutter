import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/app_exception.dart';
import '../../domain/sync/sync_engine.dart';
import 'connectivity_provider.dart';
import 'core_providers.dart';
import 'sync_engine_provider.dart';

/// The app-level sync lifecycle surfaced to the UI.
///
/// One of exactly four shapes:
///
/// * [SyncIdle] — nothing queued, last round finished cleanly,
/// * [SyncSyncing] — a round is in flight, with the queued mutation count,
/// * [SyncFailed] — the last round failed, with a user-safe message,
/// * [SyncOffline] — the device is offline; mutations queue locally.
sealed class SyncState {
  /// Constructor for the sealed subclasses.
  const SyncState();
}

/// Nothing to do / last round finished cleanly.
final class SyncIdle extends SyncState {
  /// The idle state.
  const SyncIdle();

  @override
  String toString() => 'SyncState.idle';
}

/// A sync round is currently in flight.
final class SyncSyncing extends SyncState {
  /// Creates the syncing state with the number of queued mutations.
  const SyncSyncing(this.queuedCount);

  /// Mutations in the queue when the round started.
  final int queuedCount;

  @override
  bool operator ==(Object other) =>
      other is SyncSyncing && other.queuedCount == queuedCount;

  @override
  int get hashCode => Object.hash(runtimeType, queuedCount);

  @override
  String toString() => 'SyncState.syncing($queuedCount)';
}

/// The last sync round failed; mutations stay queued for retry.
final class SyncFailed extends SyncState {
  /// Creates the failed state with a user-safe message.
  const SyncFailed(this.message);

  /// User-safe failure description (an `AppException.userMessage`).
  final String message;

  @override
  bool operator ==(Object other) =>
      other is SyncFailed && other.message == message;

  @override
  int get hashCode => Object.hash(runtimeType, message);

  @override
  String toString() => 'SyncState.failed($message)';
}

/// The device is offline; local mutations keep queueing.
final class SyncOffline extends SyncState {
  /// The offline state.
  const SyncOffline();

  @override
  String toString() => 'SyncState.offline';
}

/// Drives the sync engine and surfaces [SyncState].
///
/// Responsibilities:
///
/// * reacts to connectivity — going offline pauses syncing, regaining
///   connectivity drains the queue (`unawaited`, fire-and-forget),
/// * kicks the first round as soon as the engine materializes,
/// * coalesces bursts of mutation triggers from the repositories into one
///   round with a follow-up pass,
/// * auto-retries failed rounds with the engine's exponential backoff
///   ([SyncOutcome.retryAfter]), stopping once nothing is left to retry
///   (exhausted mutations wait for [retryFailed]),
/// * maps every failure to a user-safe message — no raw exceptions.
final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

/// The [syncControllerProvider] notifier.
class SyncController extends Notifier<SyncState> {
  Timer? _retryTimer;
  StreamSubscription<bool>? _connectivitySubscription;
  SyncEngine? _engine;
  bool _busy = false;
  bool _followUpPending = false;
  bool _initialSyncKicked = false;

  @override
  SyncState build() {
    ref.onDispose(_disposeResources);

    // The engine boots asynchronously (the in-process server binds an
    // ephemeral port); watch it so this notifier rebuilds once it is ready.
    final engineAsync = ref.watch(syncEngineProvider);
    _engine = engineAsync.hasValue ? engineAsync.value : null;

    final connectivity = ref.watch(connectivityServiceProvider);
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(
      _onConnectivityChanged,
    );

    if (_engine != null && !_initialSyncKicked) {
      _initialSyncKicked = true;
      // Deferred: never write state synchronously during build.
      unawaited(Future<void>(_kickInitialSync));
    }

    return connectivity.isOnline ? const SyncIdle() : const SyncOffline();
  }

  /// Runs a full push + pull round immediately (manual refresh, or the
  /// repository mutation trigger).
  ///
  /// While a round is in flight the call is coalesced into a single
  /// follow-up round instead of piling up concurrent pushes.
  Future<void> syncNow() async {
    if (!ref.mounted) return;
    final engine = _engine;
    if (engine == null) return;
    await _runRound(engine, engine.syncNow);
  }

  /// The manual "retry" action: resets the failure bookkeeping of
  /// exhausted mutations and pushes them again.
  Future<void> retryFailed() async {
    if (!ref.mounted) return;
    final engine = _engine;
    if (engine == null) return;
    await _runRound(engine, engine.retryFailed);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<void> _kickInitialSync() async {
    if (_engine == null) return;
    await _runRound(_engine!, _engine!.syncNow);
  }

  void _onConnectivityChanged(bool online) {
    // A queued stream event can land after disposal (the subscription
    // cancel is async) — never touch a dead Ref.
    if (!ref.mounted) return;
    if (!online) {
      state = const SyncOffline();
      return;
    }
    if (state is SyncOffline) {
      // Connection regained — drain the queue (fire-and-forget).
      state = const SyncIdle();
      final engine = _engine;
      if (engine != null) {
        unawaited(_runRound(engine, engine.syncNow));
      }
    }
  }

  Future<void> _runRound(
    SyncEngine engine,
    Future<SyncOutcome> Function() round,
  ) async {
    if (_busy) {
      _followUpPending = true;
      return;
    }
    // Rounds are fire-and-forget; they can outlive this element (container
    // shutdown in tests, dependency rebuild in the app). Bail out instead
    // of touching a dead Ref.
    if (!ref.mounted) return;
    if (!ref.read(connectivityServiceProvider).isOnline) {
      state = const SyncOffline();
      return;
    }

    _busy = true;
    _retryTimer?.cancel();
    try {
      state = SyncSyncing(await engine.queuedMutationCount());
      if (!ref.mounted) return;
      final outcome = await round();
      if (!ref.mounted) return;
      if (outcome.hasFailures) {
        final error = outcome.error;
        final message = error is AppException
            ? error.userMessage
            : 'Some changes could not be synced and will retry.';
        state = ref.read(connectivityServiceProvider).isOnline
            ? SyncFailed(message)
            : const SyncOffline();
        _scheduleRetry(
          outcome.retryAfter ??
              // A transport/pull failure with nothing queued still deserves
              // an automatic retry; exhausted mutations do not (null backoff,
              // manual retry only).
              (outcome.error != null
                  ? ref.read(appConfigProvider).retryPolicy.backoffFor(1)
                  : null),
        );
      } else {
        state = const SyncIdle();
      }
    } on AppException catch (error) {
      if (!ref.mounted) return;
      state = SyncFailed(error.userMessage);
      _scheduleRetry(ref.read(appConfigProvider).retryPolicy.backoffFor(1));
    } on Object {
      // Belt & braces: the engine maps its own errors, but a raw escape
      // must never reach the UI either.
      if (!ref.mounted) return;
      state = const SyncFailed('Something went wrong while syncing.');
      _scheduleRetry(ref.read(appConfigProvider).retryPolicy.backoffFor(1));
    } finally {
      _busy = false;
      if (_followUpPending) {
        _followUpPending = false;
        if (ref.mounted) unawaited(_runRound(engine, round));
      }
    }
  }

  /// Schedules the next automatic retry, or clears the timer when [delay]
  /// is `null` (nothing left to retry automatically).
  void _scheduleRetry(Duration? delay) {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (delay == null) return;
    _retryTimer = Timer(delay, () {
      unawaited(syncNow());
    });
  }

  void _disposeResources() {
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_connectivitySubscription?.cancel());
    _connectivitySubscription = null;
  }
}
