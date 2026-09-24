import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/clock.dart';
import '../../core/utils/id_generator.dart';

/// Injectable cross-cutting dependencies: configuration, time and ids.
///
/// Every piece of logic reads "now" and mints ids through these providers so
/// tests can pin time ([Clock]) and make ids deterministic
/// ([IdGenerator]) — no `DateTime.now()` or random sources anywhere in the
/// app logic.
///
/// Typical test overrides:
///
/// ```dart
/// final clock = MutableClock(DateTime.utc(2024, 1, 1));
/// await tester.pumpWidget(
///   ProviderScope(
///     overrides: [
///       clockProvider.overrideWithValue(clock.next),
///       appConfigProvider.overrideWithValue(const AppConfig(...)),
///       idGeneratorProvider.overrideWithValue(() => 'fixed-id'),
///     ],
///     child: const OfflineBoardApp(),
///   ),
/// );
/// ```

/// App configuration (timeouts, push batch size, retry/backoff policy).
final appConfigProvider = Provider<AppConfig>((ref) => const AppConfig());

/// The time source — real UTC wall time in production.
final clockProvider = Provider<Clock>((ref) => systemClock);

/// Generates collision-resistant, time-ordered ids for records and queued
/// mutations.
///
/// The generator instance is owned by this provider, so its in-process
/// counter keeps ids unique for the app's lifetime.
final idGeneratorProvider = Provider<IdGenerator>(
  (ref) => TimeBasedIdGenerator(clock: ref.watch(clockProvider)).next,
);
