import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:offlineboard/presentation/providers/repositories_provider.dart';
import 'package:offlineboard/presentation/screens/projects/projects_screen.dart';

import '../helpers/factories.dart';
import '../helpers/fakes.dart';

// The projects home tab over repository fakes: cards with live counts and
// progress, the empty state's guidance, and card navigation through the
// router.

void main() {
  late FakeProjectRepository projects;
  late FakeTaskRepository tasks;

  Future<void> pumpScreen(WidgetTester tester) {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ProjectsScreen()),
        GoRoute(
          path: '/project/:id',
          builder: (_, _) => const Scaffold(body: Text('PROJECT DETAIL')),
        ),
      ],
    );
    return tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectRepositoryProvider.overrideWithValue(projects),
          taskRepositoryProvider.overrideWithValue(tasks),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
  }

  setUp(() {
    projects = FakeProjectRepository([
      makeProject('p-1', name: 'Work'),
      makeProject('p-2', name: 'Home'),
      makeProject('p-3', name: 'Ideas'),
    ]);
    tasks = FakeTaskRepository([
      makeTask('t-1', projectId: 'p-1', title: 'Ship release'),
      makeTask('t-2', projectId: 'p-1', title: 'Write docs', isCompleted: true),
      makeTask('t-3', projectId: 'p-1', title: 'Review PRs'),
      makeTask('t-4', projectId: 'p-2', title: 'Buy milk'),
    ]);
  });

  testWidgets('renders one card per project with counts and progress', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('1 of 3 tasks done'), findsOneWidget);
      expect(
        find.text('No tasks yet'),
        findsOneWidget,
        reason: 'the empty project shows its own guidance',
      );

      // The progress bar's count rides the card's merged semantics
      // reading (the card is announced as a unit).
      final root = tester
          .binding
          .renderViews
          .first
          .owner
          ?.semanticsOwner
          ?.rootSemanticsNode;
      final labels = <String>[];
      void collect(SemanticsNode node) {
        if (node.label.isNotEmpty) labels.add(node.label);
        node.visitChildren((child) {
          collect(child);
          return true;
        });
      }

      collect(root!);
      expect(
        labels.any((label) => label.contains('1 of 3 tasks completed')),
        isTrue,
        reason: 'the progress bar carries a semantic count label',
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('tapping a card opens the project detail route', (tester) async {
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();

    expect(find.text('PROJECT DETAIL'), findsOneWidget);
  });

  testWidgets('no projects shows the empty state with guidance', (
    tester,
  ) async {
    projects = FakeProjectRepository();
    tasks = FakeTaskRepository();
    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('No projects yet'), findsOneWidget);
    expect(find.textContaining('works offline and syncs'), findsOneWidget);
    expect(find.text('New project'), findsOneWidget);
  });
}
