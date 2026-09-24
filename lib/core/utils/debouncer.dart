import 'dart:async';

/// Runs [call] only after [delay] of silence.
///
/// Used to keep search from thrashing the database stream pipeline on every
/// keystroke. Deliberately framework-free, so it is trivially unit-testable.
class Debouncer {
  /// Creates a debouncer that waits [delay] between events.
  Debouncer({this.delay = const Duration(milliseconds: 350)});

  final Duration delay;
  Timer? _timer;

  /// Whether a call is currently scheduled but not yet fired.
  bool get isScheduled => _timer?.isActive ?? false;

  /// Schedules [call]; reschedules if another event arrives first.
  void call(void Function() call) {
    _timer?.cancel();
    _timer = Timer(delay, call);
  }

  /// Cancels any pending scheduled call without firing it.
  void cancel() => _timer?.cancel();

  /// Cancels pending timers — call from `ref.onDispose` / `dispose`.
  void dispose() => cancel();
}
