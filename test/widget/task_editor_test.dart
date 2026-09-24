import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/presentation/providers/repositories_provider.dart';
import 'package:offlineboard/presentation/screens/tasks/task_editor_screen.dart';

import '../helpers/factories.dart';
import '../helpers/fakes.dart';

// The task editor contract over fakes: title validation surfaces as
// errorText, a valid create reaches the repository and pops back, and edit
// mode primes every field from the task snapshot. The router exists because
// a successful save pops via go_router.

void main() {
  late FakeTaskRepository tasks;
  late FakeProjectRepository projects;
  late Task existing;

  setUp(() {
    existing = makeTask(
      't-9',
      title: 'Original title',
      priority: TaskPriority.high,
    ).copyWith(notes: 'Original notes');
    tasks = FakeTaskRepository([existing]);
    projects = FakeProjectRepository([makeProject('p-1', name: 'Personal')]);
  });

  /// Pumps [editor] on a real router so `context.pop()` works after saves.
  Future<void> pumpEditor(WidgetTester tester, TaskEditorScreen editor) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('HOME')),
        ),
        GoRoute(path: '/editor', builder: (_, _) => editor),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(tasks),
          projectRepositoryProvider.overrideWithValue(projects),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    unawaited(router.push('/editor'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty title submit shows the field error, nothing saved', (
    tester,
  ) async {
    await pumpEditor(tester, const TaskEditorScreen(projectId: 'p-1'));

    await tester.tap(find.text('Create task'));
    await tester.pump();

    expect(find.text('Title is required.'), findsOneWidget);
    expect(tasks.createdTasks, isEmpty, reason: 'nothing persisted');
    expect(find.text('Create task'), findsOneWidget, reason: 'still here');
  });

  testWidgets('a valid create calls the repository and pops back', (
    tester,
  ) async {
    await pumpEditor(tester, const TaskEditorScreen(projectId: 'p-1'));

    await tester.enterText(find.byType(TextFormField), 'Buy milk');
    await tester.tap(find.text('Create task'));
    await tester.pumpAndSettle();

    expect(tasks.createdTasks, hasLength(1));
    expect(tasks.createdTasks.single.title, 'Buy milk');
    expect(tasks.createdTasks.single.projectId, 'p-1');
    expect(find.text('HOME'), findsOneWidget, reason: 'popped back to home');
    expect(find.text('Create task'), findsNothing);
  });

  testWidgets('edit mode pre-fills title and notes and updates on save', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      TaskEditorScreen(taskId: existing.id, initialTask: existing),
    );

    expect(find.text('Edit task'), findsOneWidget);
    expect(find.text('Original title'), findsOneWidget);
    expect(find.text('Original notes'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    expect(
      find.text('Completed'),
      findsOneWidget,
      reason:
          'edit mode shows '
          'the completion checkbox',
    );

    await tester.enterText(find.byType(TextFormField), 'Edited title');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    // The submit button sits below the fold of the (scrollable) form.
    final saveButton = find.widgetWithText(FilledButton, 'Save changes');
    await tester.scrollUntilVisible(
      saveButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(tasks.updatedTasks, hasLength(1));
    expect(tasks.updatedTasks.single.title, 'Edited title');
    expect(find.text('HOME'), findsOneWidget, reason: 'popped back to home');
  });
}
