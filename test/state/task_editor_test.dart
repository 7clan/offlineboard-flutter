import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/domain/entities/task_filter.dart';
import 'package:offlineboard/domain/repositories/task_repository.dart';
import 'package:offlineboard/presentation/providers/database_provider.dart';
import 'package:offlineboard/presentation/providers/repositories_provider.dart';
import 'package:offlineboard/presentation/providers/task_editor_provider.dart';

import '../helpers/fakes.dart';

// The editor controller talks to the REAL repository over an in-memory
// drift database (pinned clock + deterministic ids); the sync engine is a
// fake so the fire-and-forget mutation triggers never leave the process.

void main() {
  late MutablePinnedClock clock;
  late FakeSyncEngine engine;
  late ProviderContainer container;
  late TaskRepository tasks;

  setUp(() {
    clock = MutablePinnedClock();
    engine = FakeSyncEngine();
    container = stateTestContainer(clock: clock, engine: engine);
    tasks = container.read(taskRepositoryProvider);
  });

  /// Creates a project row so task FKs resolve; returns its id.
  Future<String> seedProject() async {
    final project = await container
        .read(projectRepositoryProvider)
        .createProject(name: 'Personal', colorValue: 1);
    return project.id;
  }

  TaskEditorController editor() => container.read(taskEditorProvider.notifier);

  /// Queue entries straight from the database under test.
  Future<List<({String entityId, MutationType type})>> queueEntries() async {
    final db = container.read(databaseProvider);
    final records = await db.syncQueueDao.queuedMutations();
    return [
      for (final record in records)
        (entityId: record.entityId, type: record.type),
    ];
  }

  group('TaskEditorController.save — validation', () {
    test(
      'empty title fails with a field error and nothing is persisted',
      () async {
        final projectId = await seedProject();
        editor().startCreate(projectId: projectId);
        editor().setTitle('   ');

        final result = await editor().save();

        expect(result, isFalse);
        expect(
          container.read(taskEditorProvider).titleError,
          'Title is required.',
        );
        expect(
          container.read(taskEditorProvider).submissionError,
          isNull,
          reason: 'validation is a field error, not a submission error',
        );
        // Only the seeded project's create is queued — no task entry.
        final entries = await queueEntries();
        expect(entries, hasLength(1));
        expect(entries.single.entityId, projectId);
        expect(await tasks.watchTasks(TaskFilter.all).first, isEmpty);
      },
    );

    test(
      'typing after a validation error clears the stale field error',
      () async {
        final projectId = await seedProject();
        editor().startCreate(projectId: projectId);
        await editor().save();
        expect(container.read(taskEditorProvider).titleError, isNotNull);

        editor().setTitle('Now valid');
        expect(container.read(taskEditorProvider).titleError, isNull);
      },
    );
  });

  group('TaskEditorController.save — create', () {
    test('persists the task locally and queues the create mutation', () async {
      final projectId = await seedProject();
      editor().startCreate(projectId: projectId);
      editor().setTitle('  Buy groceries  ');
      editor().setNotes('  Milk  ');
      editor().setPriority(TaskPriority.high);
      editor().setDueDate(1704240000000);

      final result = await editor().save();

      expect(result, isTrue);
      expect(container.read(taskEditorProvider).isSaving, isFalse);

      final list = await tasks.watchTasks(TaskFilter.all).first;
      expect(list, hasLength(1));
      final task = list.single;
      expect(task.title, 'Buy groceries', reason: 'title is trimmed');
      expect(task.notes, 'Milk', reason: 'notes are trimmed');
      expect(task.priority, TaskPriority.high);
      expect(task.dueDate, 1704240000000);
      expect(task.version, 1);
      expect(task.syncStatus, SyncStatus.pending);

      // Project create + task create are both queued for the server.
      final entries = await queueEntries();
      expect(entries, hasLength(2));
      expect(
        entries.any(
          (entry) =>
              entry.entityId == task.id && entry.type == MutationType.create,
        ),
        isTrue,
      );
    });
  });

  group('TaskEditorController.save — edit', () {
    test('edits bump version/updatedAt and queue an update mutation', () async {
      final projectId = await seedProject();
      final created = await tasks.createTask(
        projectId: projectId,
        title: 'Original',
      );
      clock.advance(const Duration(minutes: 1));

      editor().startEdit(created);
      editor().setTitle('Edited title');
      editor().setNotes('With notes');
      final result = await editor().save();

      expect(result, isTrue);
      final updated = await tasks.getTaskById(created.id);
      expect(updated!.title, 'Edited title');
      expect(updated.notes, 'With notes');
      expect(updated.version, 2, reason: 'edit bumps the version');
      expect(updated.updatedAt, greaterThan(created.updatedAt));
      expect(
        (await queueEntries()).any(
          (entry) => entry.type == MutationType.update,
        ),
        isTrue,
      );
    });

    test('clearing the notes field persists null (not empty text)', () async {
      final projectId = await seedProject();
      final created = await tasks.createTask(
        projectId: projectId,
        title: 'Task',
        notes: 'To be cleared',
      );

      editor().startEdit(created);
      editor().setNotes('');
      await editor().save();

      final updated = await tasks.getTaskById(created.id);
      expect(updated!.notes, isNull);
    });
  });

  group('TaskEditorController.delete', () {
    test('tombstones the task and queues the delete mutation', () async {
      final projectId = await seedProject();
      final created = await tasks.createTask(
        projectId: projectId,
        title: 'Delete me',
      );

      editor().startEdit(created);
      final result = await editor().delete();

      expect(result, isTrue);
      final tombstone = await tasks.getTaskById(created.id);
      expect(tombstone!.isDeleted, isTrue);
      expect(
        await tasks.watchTasks(TaskFilter.all).first,
        isEmpty,
        reason: 'tombstone hidden from lists',
      );
      expect(
        (await queueEntries()).any(
          (entry) =>
              entry.entityId == created.id && entry.type == MutationType.delete,
        ),
        isTrue,
        reason: 'a delete mutation is queued for the server',
      );
    });

    test('delete is a no-op returning false in create mode', () async {
      editor().startCreate(projectId: await seedProject());
      expect(await editor().delete(), isFalse);
    });
  });

  group('TaskEditorController.toggleCompleted', () {
    test('flips isCompleted, bumps version and queues a mutation', () async {
      final projectId = await seedProject();
      final created = await tasks.createTask(
        projectId: projectId,
        title: 'Toggle me',
      );
      expect(created.isCompleted, isFalse);
      clock.advance(const Duration(minutes: 1));

      await editor().toggleCompleted(created.id);

      final afterToggle = await tasks.getTaskById(created.id);
      expect(afterToggle!.isCompleted, isTrue);
      expect(afterToggle.version, 2);

      clock.advance(const Duration(minutes: 1));
      await editor().toggleCompleted(created.id);
      final afterSecond = await tasks.getTaskById(created.id);
      expect(afterSecond!.isCompleted, isFalse, reason: 'toggles back');
      expect(afterSecond.version, 3);
    });
  });

  group('TaskEditorController state hygiene', () {
    test('startCreate resets every field after a previous edit', () async {
      final projectId = await seedProject();
      final created = await tasks.createTask(
        projectId: projectId,
        title: 'Old title',
        notes: 'Old notes',
      );
      editor().startEdit(created);
      editor().setPriority(TaskPriority.urgent);
      editor().setCompleted(true);

      editor().startCreate(projectId: projectId);

      final state = container.read(taskEditorProvider);
      expect(state.editing, isNull);
      expect(state.title, '');
      expect(state.notes, '');
      expect(state.priority, TaskPriority.medium);
      expect(state.isCompleted, isFalse);
      expect(state.titleError, isNull);
      expect(state.submissionError, isNull);
    });

    test('isSaving is reset once a save completes', () async {
      final projectId = await seedProject();
      editor().startCreate(projectId: projectId);
      editor().setTitle('Slow save');

      final result = await editor().save();
      expect(result, isTrue);
      expect(container.read(taskEditorProvider).isSaving, isFalse);
    });
  });
}
