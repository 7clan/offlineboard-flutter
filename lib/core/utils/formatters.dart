import 'package:intl/intl.dart';

import 'clock.dart';

/// User-facing date formatting for OfflineBoard.
///
/// All app timestamps are UTC milliseconds since epoch (see
/// `docs/OFFLINE_SYNC.md`); they are converted to the device's local time
/// only at the presentation boundary, here.
abstract final class AppFormatters {
  static final DateFormat _dueFormat = DateFormat('EEE, MMM d');
  static final DateFormat _dueWithYearFormat = DateFormat('EEE, MMM d, y');
  static final DateFormat _stampFormat = DateFormat('MMM d, y · HH:mm');

  /// Compact due-date label, e.g. `Mon, Jan 5`.
  ///
  /// Returns [fallback] (defaults to `No due date`) when [millis] is null.
  static String dueDate(int? millis, {String fallback = 'No due date'}) {
    if (millis == null) return fallback;
    final date = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final now = DateTime.now();
    final sameYear = date.year == now.year;
    return (sameYear ? _dueFormat : _dueWithYearFormat).format(date);
  }

  /// Human-friendly relative due-date label: `Today`, `Tomorrow`,
  /// `3 days overdue`, `In 5 days`, falling back to a full date.
  ///
  /// `now` is injectable via [clock] for deterministic tests.
  static String dueDateRelative(int? millis, {Clock clock = systemClock}) {
    if (millis == null) return 'No due date';
    final due = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final now = clock().toLocal();

    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(due.year, due.month, due.day);
    final dayGap = dueDay.difference(today).inDays;

    if (dayGap == 0) return 'Today';
    if (dayGap == 1) return 'Tomorrow';
    if (dayGap == -1) return 'Yesterday';
    if (dayGap < 0) return '${-dayGap} days overdue';
    if (dayGap <= 7) return 'In $dayGap days';
    return _dueWithYearFormat.format(due);
  }

  /// Full timestamp label, e.g. `Jan 5, 2026 · 14:30` — for detail panes and
  /// sync diagnostics.
  static String timestamp(int millis) =>
      _stampFormat.format(DateTime.fromMillisecondsSinceEpoch(millis).toLocal());
}
