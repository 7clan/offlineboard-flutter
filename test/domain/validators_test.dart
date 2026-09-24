import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/core/utils/validators.dart';

void main() {
  group('Validators.taskTitle', () {
    test('null and blank values are rejected', () {
      expect(Validators.taskTitle(null), 'Title is required.');
      expect(Validators.taskTitle(''), 'Title is required.');
      expect(Validators.taskTitle('   \t '), 'Title is required.');
    });

    test('a trimmed non-empty title is accepted', () {
      expect(Validators.taskTitle('Buy groceries'), isNull);
      expect(Validators.taskTitle('  spaced  '), isNull);
    });

    test('titles longer than the limit are rejected at the boundary', () {
      expect(
        Validators.taskTitle('x' * Validators.maxTitleLength),
        isNull,
        reason: 'exactly maxTitleLength characters is still valid',
      );
      expect(
        Validators.taskTitle('x' * (Validators.maxTitleLength + 1)),
        'Title must be ${Validators.maxTitleLength} characters or fewer.',
      );
    });
  });

  group('Validators.projectName', () {
    test('empty project names are rejected with the field label', () {
      expect(Validators.projectName(null), 'Name is required.');
      expect(Validators.projectName('  '), 'Name is required.');
    });

    test('a valid project name passes', () {
      expect(Validators.projectName('Personal'), isNull);
    });
  });

  group('Validators.dueDateText', () {
    test('empty means "no due date" and is valid', () {
      expect(Validators.dueDateText(null), isNull);
      expect(Validators.dueDateText(''), isNull);
      expect(Validators.dueDateText(' '), isNull);
    });

    test('wrong shapes are rejected', () {
      expect(
        Validators.dueDateText('2024-1-5'),
        'Use the YYYY-MM-DD date format.',
      );
      expect(
        Validators.dueDateText('05/02/2024'),
        'Use the YYYY-MM-DD date format.',
      );
      expect(
        Validators.dueDateText('tomorrow'),
        'Use the YYYY-MM-DD date format.',
      );
    });

    test('a well-formed real calendar date is accepted', () {
      expect(Validators.dueDateText('2024-02-29'), isNull, reason: 'leap year');
      expect(Validators.dueDateText('2025-01-01'), isNull);
    });

    test('a well-formed but non-existent date is rejected', () {
      expect(Validators.dueDateText('2023-02-29'), 'This date does not exist.');
      expect(Validators.dueDateText('2025-04-31'), 'This date does not exist.');
    });
  });

  group('Validators.parseDueDateMillis', () {
    test('round-trips a date to local-midnight UTC millis', () {
      final millis = Validators.parseDueDateMillis('2025-01-31');
      expect(millis, isNotNull);
      final parsed = DateTime.fromMillisecondsSinceEpoch(millis!);
      expect(parsed.year, 2025);
      expect(parsed.month, 1);
      expect(parsed.day, 31);
      expect(parsed.hour, 0);
      expect(parsed.minute, 0);
    });

    test('returns null for garbage and impossible dates', () {
      expect(Validators.parseDueDateMillis('not-a-date'), isNull);
      expect(Validators.parseDueDateMillis('2025-13-01'), isNull);
      expect(Validators.parseDueDateMillis(''), isNull);
    });
  });

  group('Validators.dueDateTextFromMillis', () {
    test('null maps to null (no due date)', () {
      expect(Validators.dueDateTextFromMillis(null), isNull);
    });

    test('round-trips with parseDueDateMillis', () {
      const text = '2025-06-15';
      final millis = Validators.parseDueDateMillis(text);
      expect(millis, isNotNull);
      expect(Validators.dueDateTextFromMillis(millis), text);
    });
  });
}
