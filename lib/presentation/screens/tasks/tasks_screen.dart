import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/project.dart';
import '../../providers/due_window_provider.dart';
import '../../providers/project_list_provider.dart';
import '../../providers/task_list_provider.dart';
import '../../widgets/empty_view.dart';
import '../../widgets/error_view.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/task_filter_bar.dart';
import '../../widgets/task_list_item.dart';
import '../projects/project_editor_dialog.dart';

/// All tasks across projects with the shared filter bar (search, status,
/// priority, due window) and a new-task FAB.
///
/// The list itself is a [ListView.builder] over the parameterized database
/// stream — one row per task, per-project labels included.
class TasksScreen extends ConsumerWidget {
  /// Creates the screen.
  const TasksScreen({super.key});

  void _newTask(BuildContext context, WidgetRef ref, List<Project>? projects) {
    if (projects != null && projects.isEmpty) {
      // A task needs a project — guide the user to create one first.
      unawaited(showProjectEditorDialog(context));
      return;
    }
    context.push('/tasks/new');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(effectiveTaskFilterProvider);
    final tasksAsync = ref.watch(taskListProvider(filter));
    final projects = ref.watch(projectListProvider).value;
    final projectNames = {
      for (final project in projects ?? const <Project>[])
        project.id: project.name,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('All tasks')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            const TaskFilterBar(),
            const SizedBox(height: 8),
            Expanded(
              child: tasksAsync.when(
                loading: () =>
                    const ListSkeleton(count: 8, semanticLabel: 'Loading tasks'),
                error: (error, _) => ErrorView(
                  message: error is AppException
                      ? error.userMessage
                      : 'Your tasks could not be loaded.',
                  onRetry: () => ref.invalidate(taskListProvider(filter)),
                ),
                data: (tasks) {
                  if (tasks.isEmpty) {
                    if (filter.isFiltering) {
                      return EmptyView(
                        icon: Icons.filter_alt_off_outlined,
                        title: 'No matching tasks',
                        message:
                            'No tasks match the current filters. Adjust or '
                            'clear them to see everything.',
                        actionLabel: 'Clear filters',
                        actionIcon: Icons.filter_alt_off,
                        onAction: () =>
                            ref.read(dueWindowProvider.notifier).clearAll(),
                      );
                    }
                    return EmptyView(
                      icon: Icons.task_alt,
                      title: 'No tasks yet',
                      message:
                          'Create a task in any project — it is saved '
                          'locally and syncs when you connect.',
                      actionLabel: 'New task',
                      onAction: () => _newTask(context, ref, projects),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return TaskListItem(
                        task: task,
                        projectName: projectNames[task.projectId],
                        onTap: () =>
                            context.push('/tasks/${task.id}/edit', extra: task),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newTask(context, ref, projects),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
    );
  }
}
