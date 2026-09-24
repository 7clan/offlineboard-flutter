import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/presentation/providers/repositories_provider.dart';
import 'package:offlineboard/presentation/screens/tasks/task_editor_screen.dart';
import 'package:offlineboard/presentation/widgets/task_list_item.dart';

import '../helpers/factories.dart';
import '../helpers/fakes.dart';

// Responsive layout contract: the task row and the editor must not overflow
// at a small logical width (360) with 2.0× text scaling — the row reflows
// its Wrap meta line and the editor scrolls instead of clipping.

void main() {
  /// Locks the test surface to 360×800 logical pixels.
  void squeeze(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Forces 2.0× text scaling on every route below the [MaterialApp].
  Widget scaled(Widget child) {
    return Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2.0)),
        child: child,
      ),
    );
  }

  testWidgets('task row does not overflow at 360dp + 2.0x text', (
    tester,
  ) async {
    squeeze(tester);
    final task = makeTask(
      't-1',
      title: 'Ship the offline-first release notes to everyone',
      priority: TaskPriority.urgent,
      dueDate: DateTime.now().millisecondsSinceEpoch,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(FakeTaskRepository([task])),
        ],
        child: MaterialApp(
          builder: (context, child) => scaled(child!),
          home: Scaffold(
            body: ListView(
              children: [
                TaskListItem(task: task, projectName: 'Personal Projects'),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Urgent'), findsOneWidget);
  });

  testWidgets('task editor does not overflow at 360dp + 2.0x text', (
    tester,
  ) async {
    squeeze(tester);
    final existing = makeTask(
      't-9',
      title: 'A reasonably long task title for the squeezed editor',
    ).copyWith(notes: 'Some longer notes that wrap at large text scales.');

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('HOME')),
        ),
        GoRoute(
          path: '/editor',
          builder: (_, _) =>
              TaskEditorScreen(taskId: 't-9', initialTask: existing),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taskRepositoryProvider.overrideWithValue(
            FakeTaskRepository([existing]),
          ),
          projectRepositoryProvider.overrideWithValue(
            FakeProjectRepository([makeProject('p-1', name: 'Personal')]),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => scaled(child!),
        ),
      ),
    );
    unawaited(router.push('/editor'));
    await tester.pumpAndSettle();

    expect(find.text('Edit task'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Scroll the whole form at the squeezed size — every section must stay
    // inside the layout.
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Save changes'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
