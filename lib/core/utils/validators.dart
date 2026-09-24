/// Form-level validation rules shared by the editor controllers.
///
/// Validators return `null` when the value is acceptable and a user-facing
/// error message otherwise (the classic Flutter `FormField.validator`
/// contract), keeping forms accessible and logic testable.
abstract final class Validators {
  /// Maximum length of task titles and project names.
  static const int maxTitleLength = 120;

  /// `yyyy-MM-dd` (the format the date pickers emit).
  static final RegExp _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// Task titles are required and must be reasonably short.
  static String? taskTitle(String? value) => _nonEmptyTitle(value, 'Title');

  /// Project names follow the same rule as task titles.
  static String? projectName(String? value) =>
      _nonEmptyTitle(value, 'Name');

  static String? _nonEmptyTitle(String? value, String label) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return '$label is required.';
    if (trimmed.length > maxTitleLength) {
      return '$label must be $maxTitleLength characters or fewer.';
    }
    return null;
  }

  /// Validates a due-date text in `yyyy-MM-dd` form.
  ///
  /// Empty input is valid — it simply means "no due date".
  static String? dueDateText(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    if (!_datePattern.hasMatch(trimmed)) {
      return 'Use the YYYY-MM-DD date format.';
    }
    return parseDueDateMillis(trimmed) == null
        ? 'This date does not exist.'
        : null;
  }

  /// Parses `yyyy-MM-dd` into local-midnight UTC milliseconds.
  ///
  /// Returns `null` when the text is not a valid calendar date.
  static int? parseDueDateMillis(String value) {
    final trimmed = value.trim();
    if (!_datePattern.hasMatch(trimmed)) return null;
    final date = DateTime.tryParse(trimmed);
    if (date == null) return null;
    return DateTime(date.year, date.month, date.day)
        .millisecondsSinceEpoch;
  }

  /// Formats UTC millis back into the `yyyy-MM-dd` text form (round-trips
  /// with [parseDueDateMillis]).
  static String? dueDateTextFromMillis(int? millis) {
    if (millis == null) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final two = (int v) => v.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }
}
