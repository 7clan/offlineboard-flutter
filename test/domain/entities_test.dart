import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/core/utils/id_generator.dart';
import 'package:offlineboard/domain/entities/mutation_record.dart';
import 'package:offlineboard/domain/entities/project.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/domain/entities/task_filter.dart';

void main() {
  group('enum sanity — the wire and SQL encodings stay stable', () {
    test('SyncStatus covers the four badge states', () {
      expect(SyncStatus.values, hasLength(4));
      expect(
        SyncStatus.values.map((s) => s.name),
        containsAll(['synced', 'pending', 'syncing', 'failed']),
      );
    });

    test('MutationType names match the wire protocol', () {
      expect(MutationType.values.map((t) => t.name), [
        'create',
        'update',
        'delete',
      ]);
    });

    test('EntityType names match the wire protocol', () {
      expect(EntityType.values.map((t) => t.name), ['project', 'task']);
    });

    test('TaskPriority order is low → urgent (index is the SQL sort key)', () {
      expect(TaskPriority.values.map((p) => p.index), [0, 1, 2, 3]);
      expect(TaskPriority.urgent.index, greaterThan(TaskPriority.low.index));
      expect(TaskPriority.medium.label, 'Medium');
    });

    test('TaskPriority.tryFromName accepts known names only', () {
      expect(TaskPriority.tryFromName('urgent'), TaskPriority.urgent);
      expect(TaskPriority.tryFromName('URGENT'), isNull);
      expect(TaskPriority.tryFromName('nonsense'), isNull);
      expect(TaskPriority.tryFromName(null), isNull);
    });
  });

  group('MutationRecord', () {
    test('payload decodes the stored JSON text', () {
      final record = MutationRecord(
        mutationId: 'm-1',
        type: MutationType.update,
        entityType: EntityType.task,
        entityId: 't-1',
        payloadJson: jsonEncode({'id': 't-1', 'title': 'Hello'}),
        baseUpdatedAt: 10,
        baseVersion: 2,
        clientTimestamp: 30,
        queuedAt: 30,
      );
      expect(record.payload['id'], 't-1');
      expect(record.payload['title'], 'Hello');
    });

    test('copyWith replaces attempt bookkeeping only', () {
      final record = MutationRecord(
        mutationId: 'm-1',
        type: MutationType.create,
        entityType: EntityType.project,
        entityId: 'p-1',
        payloadJson: '{}',
        baseUpdatedAt: 0,
        baseVersion: 0,
        clientTimestamp: 1,
        queuedAt: 1,
      );
      final retried = record.copyWith(attempts: 4, lastError: 'offline');
      expect(retried.attempts, 4);
      expect(retried.lastError, 'offline');
      expect(retried.mutationId, record.mutationId);
      expect(retried.baseVersion, record.baseVersion);
      // Unset fields keep their values (lastError is not cleared by a null
      // pass — callers copy onto a fresh record instead).
      expect(record.copyWith(attempts: 2).lastError, isNull);
    });
  });

  group('Project JSON round-trip', () {
    final project = Project(
      id: 'p-1',
      name: 'Personal',
      colorValue: 0xFF2E7D32,
      createdAt: 100,
      updatedAt: 200,
      version: 3,
      isDeleted: false,
    );

    test('toJson → fromJson is lossless', () {
      final restored = Project.fromJson(
        (jsonDecode(jsonEncode(project.toJson())) as Map)
            .cast<String, dynamic>(),
      );
      expect(restored.id, project.id);
      expect(restored.name, project.name);
      expect(restored.colorValue, project.colorValue);
      expect(restored.createdAt, project.createdAt);
      expect(restored.updatedAt, project.updatedAt);
      expect(restored.version, project.version);
      expect(restored.isDeleted, project.isDeleted);
    });

    test('fromJson throws FormatException on missing required fields', () {
      expect(
        () => Project.fromJson(<String, dynamic>{'id': 'p-1'}),
        throwsFormatException,
      );
    });

    test('copyWith replaces only the given fields', () {
      final renamed = project.copyWith(name: 'Work', version: 4);
      expect(renamed.name, 'Work');
      expect(renamed.version, 4);
      expect(renamed.id, project.id);
      expect(renamed.createdAt, project.createdAt);
      expect(renamed.updatedAt, project.updatedAt);
    });
  });

  group('Task JSON round-trip', () {
    final task = Task(
      id: 't-1',
      projectId: 'p-1',
      title: 'Buy groceries',
      notes: 'Milk, eggs',
      priority: TaskPriority.high,
      dueDate: 1704240000000,
      isCompleted: false,
      createdAt: 100,
      updatedAt: 200,
      version: 2,
    );

    test('toJson → fromJson is lossless', () {
      final restored = Task.fromJson(
        (jsonDecode(jsonEncode(task.toJson())) as Map).cast<String, dynamic>(),
      );
      expect(restored.id, task.id);
      expect(restored.projectId, task.projectId);
      expect(restored.title, task.title);
      expect(restored.notes, task.notes);
      expect(restored.priority, task.priority);
      expect(restored.dueDate, task.dueDate);
      expect(restored.isCompleted, task.isCompleted);
      expect(restored.version, task.version);
    });

    test('fromJson rejects an unknown priority name', () {
      final json = task.toJson()..['priority'] = 'mega';
      expect(() => Task.fromJson(json), throwsFormatException);
    });

    test('fromJson tolerates missing optional fields', () {
      final json = task.toJson()
        ..remove('notes')
        ..remove('dueDate')
        ..remove('isCompleted');
      final restored = Task.fromJson(json);
      expect(restored.notes, isNull);
      expect(restored.dueDate, isNull);
      expect(restored.isCompleted, isFalse);
    });
  });

  group('TaskFilter', () {
    test('equality and hashCode cover every dimension (family caching)', () {
      const a = TaskFilter(projectId: 'p-1', search: 'x');
      const b = TaskFilter(projectId: 'p-1', search: 'x');
      const c = TaskFilter(projectId: 'p-2', search: 'x');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('copyWith can clear nullable dimensions via explicit null', () {
      const withProject = TaskFilter(
        projectId: 'p-1',
        priority: TaskPriority.low,
      );
      final cleared = withProject.copyWith(projectId: null, priority: null);
      expect(cleared.projectId, isNull);
      expect(cleared.priority, isNull);
      expect(cleared.completion, withProject.completion);
    });

    test('isFiltering reflects every narrowing dimension', () {
      expect(TaskFilter.all.isFiltering, isFalse);
      expect(const TaskFilter(search: '  ').isFiltering, isFalse);
      expect(const TaskFilter(projectId: 'p-1').isFiltering, isTrue);
      expect(
        const TaskFilter(completion: TaskCompletionFilter.completed)
            .isFiltering,
        isTrue,
      );
      expect(
        const TaskFilter(priority: TaskPriority.urgent).isFiltering,
        isTrue,
      );
      expect(const TaskFilter(dueBefore: 1).isFiltering, isTrue);
      expect(const TaskFilter(search: 'gro').isFiltering, isTrue);
    });
  });

  group('TimeBasedIdGenerator', () {
    test('deterministic with a pinned clock: micros stamp + counter', () {
      final pinned = DateTime.utc(2025, 1, 1);
      final generator = TimeBasedIdGenerator(clock: () => pinned);
      final first = generator.next();
      final second = generator.next();
      expect(first, '${pinned.microsecondsSinceEpoch.toRadixString(36)}-0');
      expect(second, '${pinned.microsecondsSinceEpoch.toRadixString(36)}-1');
      expect(first, isNot(second), reason: 'same-microsecond uniqueness');
    });
  });
}
