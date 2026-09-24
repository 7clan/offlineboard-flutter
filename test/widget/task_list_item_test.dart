import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/domain/entities/sync_enums.dart';
import 'package:offlineboard/presentation/providers/repositories_provider.dart';
import 'package:offlineboard/presentation/widgets/task_list_item.dart';

import '../helpers/factories.dart';
import '../helpers/fakes.dart';

// Task row contract: content (title, due chip, priority), the 48dp
// state-following completion semantics, and the toggle routing through the
// editor controller into the (faked) repository.

/// Local-midnight millis for [dayOffset] days from today.
int dayMillis(int dayOffset) {
  final now = DateTime.now();
  return DateTime(
    now.year,
    now.month,
    now.day,
  ).add(Duration(days: dayOffset)).millisecondsSinceEpoch;
}

void main() {
  late FakeTaskRepository repo;
  late Task task;

  setUp(() {
    task = makeTask(
      't-1',
      title: 'Fix the sink',
      priority: TaskPriority.urgent,
      dueDate: dayMillis(0),
    );
    // The row is a prop; the toggle path resolves the task through the
    // repository, so the fake must know it.
    repo = FakeTaskRepository([task]);
  });

  Future<void> pumpItem(
    WidgetTester tester, {
    Task? item,
    String? projectName,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        overrides: [taskRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                TaskListItem(task: item ?? task, projectName: projectName),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders title, due chip and priority label', (tester) async {
    await pumpItem(tester, projectName: 'Home');

    expect(find.text('Fix the sink'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget, reason: 'the due chip');
    expect(find.text('Urgent'), findsOneWidget, reason: 'the priority label');
    expect(find.text('Home'), findsOneWidget, reason: 'the project label');
    expect(find.bySemanticsLabel('Project: Home'), findsOneWidget);
    expect(find.bySemanticsLabel('Priority: Urgent'), findsOneWidget);
    expect(find.bySemanticsLabel('Due Today'), findsOneWidget);
  });

  testWidgets('checkbox tap toggles completion through the editor controller', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await pumpItem(tester);
      expect(repo.completedCalls, isEmpty);

      // Drive the row the way an assistive-technology user would.
      await tester.tap(
        find.bySemanticsLabel("Mark task 'Fix the sink' as complete"),
      );
      await tester.pump();

      expect(
        repo.completedCalls,
        [('t-1', true)],
        reason:
            'the editor controller called setCompleted on the fake '
            'repository',
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets("the completion semantics label follows the task's state", (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await pumpItem(tester);
      expect(
        find.bySemanticsLabel("Mark task 'Fix the sink' as complete"),
        findsOneWidget,
      );

      // Same row, task now completed — the label must flip.
      await pumpItem(tester, item: task.copyWith(isCompleted: true));
      expect(
        find.bySemanticsLabel("Mark task 'Fix the sink' as not complete"),
        findsOneWidget,
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('the checkbox semantics target is at least 48dp', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await pumpItem(tester);

      // Walk the semantics tree via the render views' pipeline owner (the
      // non-deprecated path) and measure the checkbox node's rect.
      final owner = tester.binding.renderViews.first.owner;
      final root = owner?.semanticsOwner?.rootSemanticsNode;
      expect(root, isNotNull, reason: 'semantics must be enabled');

      SemanticsNode? findLabel(SemanticsNode node, String label) {
        if (node.label == label) return node;
        SemanticsNode? found;
        node.visitChildren((child) {
          found ??= findLabel(child, label);
          return found == null;
        });
        return found;
      }

      final node = findLabel(root!, "Mark task 'Fix the sink' as complete");
      expect(node, isNotNull, reason: 'the checkbox carries its label');
      expect(
        node!.rect.width,
        greaterThanOrEqualTo(48),
        reason: 'touch target width (Material accessibility guideline)',
      );
      expect(
        node.rect.height,
        greaterThanOrEqualTo(48),
        reason: 'touch target height (Material accessibility guideline)',
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('an overdue task renders the relative overdue label', (
    tester,
  ) async {
    await pumpItem(tester, item: task.copyWith(dueDate: dayMillis(-3)));
    expect(find.text('3 days overdue'), findsOneWidget);
    expect(find.bySemanticsLabel('Due 3 days overdue'), findsOneWidget);
  });

  testWidgets('a pending sync status is labeled on the status icon', (
    tester,
  ) async {
    await pumpItem(tester, item: task.copyWith(syncStatus: SyncStatus.pending));
    expect(find.bySemanticsLabel('Waiting to sync'), findsOneWidget);
  });
}
