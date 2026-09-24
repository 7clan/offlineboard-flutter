/// Signature for a time source.
///
/// Every piece of logic that needs "now" receives a [Clock] instead of
/// calling `DateTime.now()` directly, so tests can pin time and stay
/// deterministic (crucial for the last-write-wins conflict strategy, which
/// compares timestamps).
typedef Clock = DateTime Function();

/// The production clock — real wall time.
///
/// Returns UTC so that every timestamp derived from it is unambiguous.
DateTime systemClock() => DateTime.now().toUtc();
