import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlineboard/domain/entities/task.dart';
import 'package:offlineboard/domain/entities/task_filter.dart';
import 'package:offlineboard/presentation/providers/repositories_provider.dart';
import 'package:offlineboard/presentation/providers/task_filters_provider.dart';
import 'package:offlineboard/presentation/providers/task_list_provider.dart';

import '../helpers/fakes.dart';

// Filter-state tests: every dimension commits to the state immediately and
// feeds ONE parameterized re-query through taskListProvider — except the
// search text, which is debounced (350 ms) so a burst of keystrokes becomes
// a single re-query. The RecordingTaskRepository counts the queries.

/// Watches the task list exactly like the TasksScreen does (filter →
/// family), so filter commits turn into repository re-queries.
final _watchedTasks = Provider<List<Task>>(
  (ref) =>
      ref.watch(taskListProvider(ref.watch(activeTaskFilterProvider))).value ??
      const <Task>[],
);

Future<void> settle([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late RecordingTaskRepository repo;
  late ProviderContainer container;
  late TaskFilterController controller;

  setUp(() {
    repo = RecordingTaskRepository();
    container = ProviderContainer(
      overrides: [taskRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    addTearDown(repo.dispose);
    controller = container.read(taskFilterStateProvider.notifier);
    container.listen(_watchedTasks, (_, _) {});
  });

  group('TaskFilterState (pure)', () {
    test('starts empty and not filtering', () {
      final state = container.read(taskFilterStateProvider);
      expect(state, TaskFilterState.empty);
      expect(state.isFiltering, isFalse);
      expect(state.toTaskFilter(), TaskFilter.all);
    });

    test('setters update their dimension and toTaskFilter maps them', () {
      controller.setProject('p-1');
      controller.setCompletion(TaskCompletionFilter.incomplete);
      controller.setPriority(TaskPriority.urgent);
      controller.setDueBefore(1704240000000);
      controller.setSearch('off');

      final filter = container.read(taskFilterStateProvider).toTaskFilter();
      expect(filter.projectId, 'p-1');
      expect(filter.completion, TaskCompletionFilter.incomplete);
      expect(filter.priority, TaskPriority.urgent);
      expect(filter.dueBefore, 1704240000000);
      expect(filter.search, 'off');
      expect(container.read(taskFilterStateProvider).isFiltering, isTrue);
    });

    test('clear resets every dimension at once', () {
      controller.setProject('p-1');
      controller.setPriority(TaskPriority.high);
      controller.setSearch('stale');
      controller.clear();

      expect(container.read(taskFilterStateProvider), TaskFilterState.empty);
    });
  });

  group('search debounce (350 ms)', () {
    test('a burst of keystrokes becomes ONE re-query', () async {
      await settle();
      expect(repo.watchedFilters, hasLength(1), reason: 'the initial query');
      expect(repo.watchedFilters.single.search, isEmpty);

      // Four keystrokes in one burst — a naive wiring would re-query
      // four times.
      controller.onSearchChanged('of');
      controller.onSearchChanged('off');
      controller.onSearchChanged('offli');
      controller.onSearchChanged('offline');

      expect(
        repo.watchedFilters,
        hasLength(1),
        reason: 'no re-query while the debounce is pending',
      );

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        repo.watchedFilters,
        hasLength(1),
        reason: 'still inside the 350 ms window',
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(container.read(taskFilterStateProvider).search, 'offline');
      expect(
        repo.watchedFilters,
        hasLength(2),
        reason: 'exactly one re-query for the whole burst',
      );
      expect(repo.watchedFilters.last.search, 'offline');
    });

    test('clear cancels a pending burst — no re-query at all', () async {
      await settle();
      expect(repo.watchedFilters, hasLength(1));

      controller.onSearchChanged('never');
      controller.clear();

      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        container.read(taskFilterStateProvider).search,
        isEmpty,
        reason: 'the debounced commit never fired',
      );
      expect(
        repo.watchedFilters,
        hasLength(1),
        reason: 'the empty filter matches the initial query',
      );
    });

    test('setSearch commits immediately, bypassing the debounce', () async {
      await settle();
      controller.setSearch('direct');

      await settle();
      expect(container.read(taskFilterStateProvider).search, 'direct');
      expect(repo.watchedFilters, hasLength(2));
      expect(repo.watchedFilters.last.search, 'direct');
    });
  });

  group('non-search dimensions', () {
    test(
      'commit immediately — no debounce on chips and project pick',
      () async {
        await settle();
        expect(repo.watchedFilters, hasLength(1));

        controller.setCompletion(TaskCompletionFilter.incomplete);
        await settle();
        expect(repo.watchedFilters, hasLength(2));
        expect(
          repo.watchedFilters.last.completion,
          TaskCompletionFilter.incomplete,
        );

        controller.setProject('p-9');
        await settle();
        expect(repo.watchedFilters, hasLength(3));
        expect(repo.watchedFilters.last.projectId, 'p-9');
      },
    );
  });
}
