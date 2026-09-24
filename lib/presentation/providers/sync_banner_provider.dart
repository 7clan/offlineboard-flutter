import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'queue_badge_provider.dart';
import 'sync_controller.dart';

/// What the global sync banner currently shows.
enum SyncBannerKind {
  /// Nothing worth saying — hide the banner.
  hidden,

  /// Offline: changes keep saving locally.
  offline,

  /// Mutations are queued but no round is in flight.
  pending,

  /// A sync round is in flight.
  syncing,

  /// The last round failed; mutations stay queued.
  failed,

  /// Everything just synced — shown briefly, then hidden.
  synced,
}

/// The sync banner's derived state.
class SyncBannerState {
  /// Creates the banner state.
  const SyncBannerState({required this.kind, this.message, this.queuedCount = 0});

  /// Which banner variant to show.
  final SyncBannerKind kind;

  /// User-facing message (`null` lets the widget compose a default).
  final String? message;

  /// The queue size that goes with the banner.
  final int queuedCount;

  /// The hidden banner.
  static const SyncBannerState hidden = SyncBannerState(
    kind: SyncBannerKind.hidden,
  );

  @override
  bool operator ==(Object other) {
    return other is SyncBannerState &&
        other.kind == kind &&
        other.message == message &&
        other.queuedCount == queuedCount;
  }

  @override
  int get hashCode => Object.hash(kind, message, queuedCount);
}

/// Maps the sync controller and the live queue size into the banner state.
///
/// Pure presentation state: no engine or repository calls live here — the
/// banner's buttons delegate to the sync controller.
final syncBannerProvider = NotifierProvider<SyncBannerController, SyncBannerState>(
  SyncBannerController.new,
);

/// The [syncBannerProvider] notifier.
class SyncBannerController extends Notifier<SyncBannerState> {
  Timer? _dismissTimer;
  SyncBannerKind _previous = SyncBannerKind.hidden;

  @override
  SyncBannerState build() {
    ref.onDispose(_dispose);
    final sync = ref.watch(syncControllerProvider);
    final queued = ref.watch(queueBadgeProvider).value ?? 0;
    return _map(sync, queued);
  }

  /// Manual "Sync now" (banner button).
  Future<void> syncNow() => ref.read(syncControllerProvider.notifier).syncNow();

  /// Manual "Retry" after a failed round (banner button).
  Future<void> retry() => ref.read(syncControllerProvider.notifier).retryFailed();

  SyncBannerState _map(SyncState sync, int queued) {
    final SyncBannerState next;
    switch (sync) {
      case SyncOffline():
        next = const SyncBannerState(
          kind: SyncBannerKind.offline,
          message: 'Offline — changes are saved locally and will sync '
              'when you reconnect.',
        );
      case SyncSyncing(:final queuedCount):
        next = SyncBannerState(
          kind: SyncBannerKind.syncing,
          queuedCount: queuedCount,
        );
      case SyncFailed(:final message):
        next = SyncBannerState(
          kind: SyncBannerKind.failed,
          message: message,
          queuedCount: queued,
        );
      case SyncIdle():
        if (queued > 0) {
          next = SyncBannerState(
            kind: SyncBannerKind.pending,
            queuedCount: queued,
          );
        } else if (_previous == SyncBannerKind.syncing ||
            _previous == SyncBannerKind.pending ||
            _previous == SyncBannerKind.failed) {
          // A round just finished cleanly — confirm briefly, then hide.
          _scheduleDismiss();
          next = const SyncBannerState(
            kind: SyncBannerKind.synced,
            message: 'All changes synced.',
          );
        } else {
          next = SyncBannerState.hidden;
        }
    }
    _previous = next.kind;
    return next;
  }

  void _scheduleDismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 3), () {
      if (state.kind == SyncBannerKind.synced) {
        state = SyncBannerState.hidden;
      }
    });
  }

  void _dispose() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
  }
}
