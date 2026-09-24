import 'clock.dart';

/// Signature for identifiers generators (entities + queued mutations).
///
/// Injected everywhere an id is minted, so tests can hand out deterministic
/// ids and assert on them. The production implementation is
/// [TimeBasedIdGenerator].
typedef IdGenerator = String Function();

/// Generates collision-resistant, time-ordered ids without a random source.
///
/// The id is `<micros-since-epoch in base36>-<counter in base36>`:
///
/// * the microsecond stamp makes ids unique across processes and reboots,
/// * the in-process counter makes ids unique within the same microsecond.
///
/// With an injected [Clock] the output is fully deterministic, which keeps
/// unit tests stable (no unseeded randomness anywhere in the app).
class TimeBasedIdGenerator {
  /// Creates a generator reading time from [clock] (defaults to the real
  /// system clock).
  TimeBasedIdGenerator({Clock? clock}) : _clock = clock ?? systemClock;

  final Clock _clock;
  int _counter = 0;

  /// Returns a fresh unique id (also usable as an idempotency key).
  String next() {
    final stamp = _clock().microsecondsSinceEpoch.toRadixString(36);
    final sequence = (_counter++).toRadixString(36);
    return '$stamp-$sequence';
  }
}
