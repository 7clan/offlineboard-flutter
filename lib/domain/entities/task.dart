import 'sync_enums.dart';

/// Task priority, ordered from least to most urgent (the enum index is the
/// sort key used in SQL).
enum TaskPriority {
  /// Nice-to-have, no deadline pressure.
  low('Low'),

  /// Normal work.
  medium('Medium'),

  /// Should be handled soon.
  high('High'),

  /// Needs attention today.
  urgent('Urgent');

  const TaskPriority(this.label);

  /// User-facing label (also used for semantics labels in the UI).
  final String label;

  /// Parses a priority by wire name; `null` when unknown (callers decide
  /// whether that is malformed input or a default).
  static TaskPriority? tryFromName(String? name) {
    if (name == null) return null;
    for (final priority in TaskPriority.values) {
      if (priority.name == name) return priority;
    }
    return null;
  }
}

/// A task in the OfflineBoard domain.
///
/// Timestamps are UTC milliseconds since epoch; `version` bumps on every
/// local edit; `isDeleted` marks tombstones. See [Project] for the
/// last-write-wins implications.
class Task {
  /// Creates a task snapshot.
  const Task({
    required this.id,
    required this.projectId,
    required this.title,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    this.notes,
    this.dueDate,
    this.isCompleted = false,
    this.isDeleted = false,
    this.syncStatus = SyncStatus.synced,
  });

  /// Client-generated opaque id.
  final String id;

  /// Owning project id.
  final String projectId;

  /// Title (required, validated non-empty).
  final String title;

  /// Free-form notes, optional.
  final String? notes;

  /// Priority used for ordering and filtering.
  final TaskPriority priority;

  /// Due date (UTC millis of local midnight), optional.
  final int? dueDate;

  /// Whether the task is done.
  final bool isCompleted;

  /// Creation time (UTC millis).
  final int createdAt;

  /// Last modification time (UTC millis) — the LWW comparison key.
  final int updatedAt;

  /// Monotonic edit counter — the conflict-detection key.
  final int version;

  /// Whether this record is a tombstone (deleted).
  final bool isDeleted;

  /// Derived, never persisted: how this record stands vs. the server.
  final SyncStatus syncStatus;

  static const _kId = 'id';
  static const _kProjectId = 'projectId';
  static const _kTitle = 'title';
  static const _kNotes = 'notes';
  static const _kPriority = 'priority';
  static const _kDueDate = 'dueDate';
  static const _kIsCompleted = 'isCompleted';
  static const _kCreatedAt = 'createdAt';
  static const _kUpdatedAt = 'updatedAt';
  static const _kVersion = 'version';
  static const _kIsDeleted = 'isDeleted';

  /// Serializes to the sync payload / wire JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
    _kId: id,
    _kProjectId: projectId,
    _kTitle: title,
    _kNotes: notes,
    _kPriority: priority.name,
    _kDueDate: dueDate,
    _kIsCompleted: isCompleted,
    _kCreatedAt: createdAt,
    _kUpdatedAt: updatedAt,
    _kVersion: version,
    _kIsDeleted: isDeleted,
  };

  /// Parses the sync payload / wire JSON form.
  ///
  /// Throws [FormatException] when a required field is missing, mistyped or
  /// carries an unknown priority name, so transport code can map it to a
  /// `MalformedResponseException`.
  factory Task.fromJson(Map<String, dynamic> json) {
    final priorityName = json[_kPriority];
    final priority = TaskPriority.tryFromName(
      priorityName is String ? priorityName : null,
    );
    if (priority == null) {
      throw FormatException('Task record has an unknown priority.');
    }
    final dueDate = json[_kDueDate];
    final notes = json[_kNotes];
    return Task(
      id: _required<String>(json, _kId),
      projectId: _required<String>(json, _kProjectId),
      title: _required<String>(json, _kTitle),
      notes: notes is String ? notes : null,
      priority: priority,
      dueDate: dueDate is num ? dueDate.toInt() : null,
      isCompleted: json[_kIsCompleted] == true,
      createdAt: _required<num>(json, _kCreatedAt).toInt(),
      updatedAt: _required<num>(json, _kUpdatedAt).toInt(),
      version: _required<num>(json, _kVersion).toInt(),
      isDeleted: json[_kIsDeleted] == true,
    );
  }

  static T _required<T>(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! T) {
      throw FormatException('Task record is missing "$key".');
    }
    return value;
  }

  /// Returns a copy with the given fields replaced.
  ///
  /// `id` and `createdAt` are immutable by design.
  Task copyWith({
    String? projectId,
    String? title,
    String? notes,
    TaskPriority? priority,
    int? dueDate,
    bool? isCompleted,
    int? updatedAt,
    int? version,
    bool? isDeleted,
    SyncStatus? syncStatus,
  }) {
    return Task(
      id: id,
      projectId: projectId ?? this.projectId,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      priority: priority ?? this.priority,
      dueDate: dueDate ?? this.dueDate,
      isCompleted: isCompleted ?? this.isCompleted,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      isDeleted: isDeleted ?? this.isDeleted,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}
