import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/core/utils/clock.dart';
import 'package:offlineboard/core/utils/formatters.dart';

void main() {
  // A pinned "today": 2025-03-15 local.
  final pinnedNow = DateTime(2025, 3, 15, 12, 30);

  DateTime localMidnight(int year, int month, int day) =>
      DateTime(year, month, day);

  int millisOf(int year, int month, int day) =>
      localMidnight(year, month, day).millisecondsSinceEpoch;

  group('AppFormatters.dueDateRelative', () {
    Clock fixedClock() =>
        () => pinnedNow;

    test('null → No due date', () {
      expect(
        AppFormatters.dueDateRelative(null, clock: fixedClock()),
        'No due date',
      );
    });

    test('due today → Today', () {
      expect(
        AppFormatters.dueDateRelative(
          millisOf(2025, 3, 15),
          clock: fixedClock(),
        ),
        'Today',
      );
    });

    test('due tomorrow → Tomorrow', () {
      expect(
        AppFormatters.dueDateRelative(
          millisOf(2025, 3, 16),
          clock: fixedClock(),
        ),
        'Tomorrow',
      );
    });

    test('due yesterday → Yesterday', () {
      expect(
        AppFormatters.dueDateRelative(
          millisOf(2025, 3, 14),
          clock: fixedClock(),
        ),
        'Yesterday',
      );
    });

    test('past beyond yesterday → N days overdue', () {
      expect(
        AppFormatters.dueDateRelative(
          millisOf(2025, 3, 10),
          clock: fixedClock(),
        ),
        '5 days overdue',
      );
    });

    test('within the coming week → In N days', () {
      expect(
        AppFormatters.dueDateRelative(
          millisOf(2025, 3, 20),
          clock: fixedClock(),
        ),
        'In 5 days',
      );
      expect(
        AppFormatters.dueDateRelative(
          millisOf(2025, 3, 22),
          clock: fixedClock(),
        ),
        'In 7 days',
      );
    });

    test('far future falls back to the full date with year', () {
      expect(
        AppFormatters.dueDateRelative(
          millisOf(2025, 6, 15),
          clock: fixedClock(),
        ),
        contains('2025'),
      );
    });
  });

  group('AppFormatters.dueDate', () {
    test('null → fallback text', () {
      expect(AppFormatters.dueDate(null), 'No due date');
      expect(AppFormatters.dueDate(null, fallback: '—'), '—');
    });

    test('a real date formats compactly', () {
      final label = AppFormatters.dueDate(millisOf(2025, 1, 5));
      expect(label, contains('Jan'));
      expect(label, contains('5'));
    });
  });

  group('AppFormatters.timestamp', () {
    test('renders date and 24h clock time', () {
      final label = AppFormatters.timestamp(
        DateTime(2025, 1, 5, 14, 30).millisecondsSinceEpoch,
      );
      expect(label, contains('2025'));
      expect(label, contains('14:30'));
    });
  });
}
