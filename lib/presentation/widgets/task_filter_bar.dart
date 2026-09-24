import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/entities/task.dart';
import '../../../domain/entities/task_filter.dart';
import '../providers/due_window_provider.dart';
import '../providers/task_filters_provider.dart';

/// The shared task filter bar: debounced search field plus chip rows for
/// completion, priority and due window.
///
/// State lives entirely in providers ([taskFilterStateProvider] owns the
/// search/completion/priority dims, [dueWindowProvider] the window); this
/// widget only renders and forwards. The raw keystrokes stay in the local
/// text field until the 350 ms debounce commits them, so the database
/// stream pipeline is not thrashed per character.
///
/// A [Wrap] per row keeps the bar reflowing (not overflowing) at large text
/// scales; every chip is a standard Material [ChoiceChip] with built-in
/// selected-state semantics.
class TaskFilterBar extends ConsumerStatefulWidget {
  /// Creates the bar.
  const TaskFilterBar({super.key});

  @override
  ConsumerState<TaskFilterBar> createState() => _TaskFilterBarState();
}

class _TaskFilterBarState extends ConsumerState<TaskFilterBar> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ref.read(taskFilterStateProvider).search,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearAll() {
    ref.read(dueWindowProvider.notifier).clearAll();
    _searchController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(taskFilterStateProvider);
    final window = ref.watch(dueWindowProvider);
    final theme = Theme.of(context);

    final filtering = filter.isFiltering || window != DueWindow.any;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onChanged: ref
                      .read(taskFilterStateProvider.notifier)
                      .onSearchChanged,
                  decoration: InputDecoration(
                    hintText: 'Search tasks',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: filter.search.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              ref
                                  .read(taskFilterStateProvider.notifier)
                                  .setSearch('');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              if (filtering) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  tooltip: 'Clear all filters',
                  onPressed: _clearAll,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Status', style: theme.textTheme.labelMedium),
              for (final (:value, :label) in _completionOptions)
                ChoiceChip(
                  label: Text(label),
                  selected: filter.completion == value,
                  onSelected: (_) => ref
                      .read(taskFilterStateProvider.notifier)
                      .setCompletion(value),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Priority', style: theme.textTheme.labelMedium),
              for (final (:value, :label) in _priorityOptions)
                ChoiceChip(
                  label: Text(label),
                  selected: value == null
                      ? filter.priority == null
                      : filter.priority == value,
                  onSelected: (_) => ref
                      .read(taskFilterStateProvider.notifier)
                      .setPriority(value),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Due', style: theme.textTheme.labelMedium),
              for (final value in DueWindow.values)
                ChoiceChip(
                  label: Text(value.label),
                  selected: window == value,
                  onSelected: (_) =>
                      ref.read(dueWindowProvider.notifier).setWindow(value),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static const _completionOptions =
      <({TaskCompletionFilter value, String label})>[
        (value: TaskCompletionFilter.all, label: 'All'),
        (value: TaskCompletionFilter.incomplete, label: 'Pending'),
        (value: TaskCompletionFilter.completed, label: 'Completed'),
      ];

  static const _priorityOptions = <({TaskPriority? value, String label})>[
    (value: null, label: 'Any'),
    (value: TaskPriority.low, label: 'Low'),
    (value: TaskPriority.medium, label: 'Medium'),
    (value: TaskPriority.high, label: 'High'),
    (value: TaskPriority.urgent, label: 'Urgent'),
  ];
}
