import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/data/db/app_database.dart';
import 'package:offlineboard/domain/entities/mutation_record.dart';
import 'package:offlineboard/domain/entities/project.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';

/// Shared factories for DAO/database tests — deterministic ids, timestamps
/// and versions so assertions stay exact.
const t0 = 1735689600000; // 2025-01-01T00:00:00Z.

Project makeProject(
  String id, {
  String name = 'Project',
  int updatedAt = t0,
  int version = 1,
  bool isDeleted = false,
}) {
  return Project(
    id: id,
    name: name,
    colorValue: 0xFF2E7D32,
    createdAt: t0,
    updatedAt: updatedAt,
    version: version,
    isDeleted: isDeleted,
  );
}

Task makeTask(
  String id, {
  String projectId = 'p-1',
  String title = 'Task',
  TaskPriority priority = TaskPriority.medium,
  int? dueDate,
  bool isCompleted = false,
  int updatedAt = t0,
  int version = 1,
  bool isDeleted = false,
}) {
  return Task(
    id: id,
    projectId: projectId,
    title: title,
    priority: priority,
    dueDate: dueDate,
    isCompleted: isCompleted,
    createdAt: t0,
    updatedAt: updatedAt,
    version: version,
    isDeleted: isDeleted,
  );
}

/// Opens a fresh in-memory [AppDatabase] and closes it automatically.
AppDatabase memoryDb() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

/// Queue-entry factory with defaults that exercise nothing special.
MutationRecord makeMutation(
  String mutationId, {
  MutationType type = MutationType.update,
  EntityType entityType = EntityType.task,
  String entityId = 't-1',
  String payloadJson = '{}',
  int baseUpdatedAt = 0,
  int baseVersion = 1,
  int clientTimestamp = t0,
  int queuedAt = t0,
  int attempts = 0,
}) {
  return MutationRecord(
    mutationId: mutationId,
    type: type,
    entityType: entityType,
    entityId: entityId,
    payloadJson: payloadJson,
    baseUpdatedAt: baseUpdatedAt,
    baseVersion: baseVersion,
    clientTimestamp: clientTimestamp,
    queuedAt: queuedAt,
    attempts: attempts,
  );
}
