import 'sync_enums.dart';

/// A project in the OfflineBoard domain.
///
/// Timestamps (`createdAt`, `updatedAt`) are UTC milliseconds since epoch —
/// the currency of the last-write-wins conflict strategy. `version` bumps on
/// every local edit and is what the server compares against a mutation's
/// base version to detect conflicts. Soft deletes (`isDeleted`) keep
/// tombstones around so deletes can sync.
class Project {
  /// Creates a project snapshot.
  const Project({
    required this.id,
    required this.name,
    required this.colorValue,
    required this.createdAt,
    required this.updatedAt,
    required this.version,
    this.isDeleted = false,
    this.syncStatus = SyncStatus.synced,
  });

  /// Client-generated opaque id (see `TimeBasedIdGenerator`).
  final String id;

  /// Display name.
  final String name;

  /// Material color value (ARGB int) used for the project accent.
  final int colorValue;

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

  /// JSON keys used by the sync queue payloads and the wire protocol.
  static const _kId = 'id';
  static const _kName = 'name';
  static const _kColor = 'colorValue';
  static const _kCreatedAt = 'createdAt';
  static const _kUpdatedAt = 'updatedAt';
  static const _kVersion = 'version';
  static const _kIsDeleted = 'isDeleted';

  /// Serializes to the sync payload / wire JSON form.
  Map<String, dynamic> toJson() => <String, dynamic>{
    _kId: id,
    _kName: name,
    _kColor: colorValue,
    _kCreatedAt: createdAt,
    _kUpdatedAt: updatedAt,
    _kVersion: version,
    _kIsDeleted: isDeleted,
  };

  /// Parses the sync payload / wire JSON form.
  ///
  /// Throws [FormatException] when a required field is missing or has the
  /// wrong type, so transport code can map it to a
  /// `MalformedResponseException`.
  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: _required<String>(json, _kId),
      name: _required<String>(json, _kName),
      colorValue: _required<num>(json, _kColor).toInt(),
      createdAt: _required<num>(json, _kCreatedAt).toInt(),
      updatedAt: _required<num>(json, _kUpdatedAt).toInt(),
      version: _required<num>(json, _kVersion).toInt(),
      isDeleted: json[_kIsDeleted] == true,
    );
  }

  static T _required<T>(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! T) {
      throw FormatException('Project record is missing "$key".');
    }
    return value;
  }

  /// Returns a copy with the given fields replaced.
  ///
  /// `id` and `createdAt` are immutable by design.
  Project copyWith({
    String? name,
    int? colorValue,
    int? updatedAt,
    int? version,
    bool? isDeleted,
    SyncStatus? syncStatus,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      isDeleted: isDeleted ?? this.isDeleted,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}
