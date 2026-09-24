import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/project.dart';
import '../../providers/due_window_provider.dart';
import '../../providers/entity_by_id_providers.dart';
import '../../providers/project_editor_provider.dart';
import '../../providers/project_stats_provider.dart';
import '../../providers/task_list_provider.dart';
import '../../widgets/confirm_delete_dialog.dart';
import '../../widgets/empty_view.dart';
import '../../widgets/error_view.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/task_filter_bar.dart';
import '../../widgets/task_list_item.dart';
import 'project_editor_dialog.dart';

/// One project: header with progress, the filtered task list and a
/// new-task FAB. Edit and delete live in the app-bar menu; deletion is
/// confirmed with an explanation of the queued (offline-safe) delete.
class ProjectDetailScreen extends ConsumerWidget {
  /// Creates the screen for [projectId].
  const ProjectDetailScreen({super.key, required this.projectId});

  /// The project shown on this page.
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectByIdProvider(projectId));

    return Scaffold(
      appBar: AppBar(title: const Text('Project')),
      body: SafeArea(
        top: false,
        child: projectAsync.when(
          loading: () =>
              const ListSkeleton(count: 6, semanticLabel: 'Loading project'),
          error: (error, _) => ErrorView(
            message: error is AppException
                ? error.userMessage
                : 'This project could not be loaded.',
            onRetry: () => ref.invalidate(projectByIdProvider(projectId)),
          ),
          data: (project) {
            if (project == null || project.isDeleted) {
              return EmptyView(
                icon: Icons.folder_delete_outlined,
                title: 'Project deleted',
                message:
                    'This project no longer exists on this device. The '
                    'deletion will sync to the server when you connect.',
                actionLabel: 'Back to projects',
                actionIcon: Icons.arrow_back,
                onAction: () => context.go('/'),
              );
            }
            return _ProjectDetail(project: project, projectId: projectId);
          },
        ),
      ),
    );
  }
}

/// The loaded detail page: app-bar menu, header, filter bar, task list, FAB.
class _ProjectDetail extends ConsumerWidget {
  const _ProjectDetail({required this.project, required this.projectId});

  final Project project;
  final String projectId;

  Future<void> _edit(BuildContext context) async {
    final result = await showProjectEditorDialog(context, project: project);
    if (result == ProjectEditorResult.deleted && context.mounted) {
      context.go('/');
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final stats =
        ref.read(projectStatsProvider)[project.id] ?? ProjectStats.empty;
    final taskCount = stats.total == 0 ? 'no tasks' : '${stats.total} task(s)';
    final confirmed = await showConfirmDeleteDialog(
      context,
      title: 'Delete project?',
      message:
          "This deletes '${project.name}' and $taskCount on this device. "
          'The deletion is saved locally and will sync to the server when '
          'you are back online.',
      confirmLabel: 'Delete project',
    );
    if (!confirmed || !context.mounted) return;

    final controller = ref.read(projectEditorProvider.notifier);
    controller.startEdit(project);
    final deleted = await controller.delete();
    if (!context.mounted) return;
    if (deleted) {
      context.go('/');
    } else {
      final message =
          ref.read(projectEditorProvider).submissionError ??
          'The project could not be deleted.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final stats =
        ref.watch(projectStatsProvider)[projectId] ?? ProjectStats.empty;
    final filter = ref
        .watch(effectiveTaskFilterProvider)
        .copyWith(projectId: projectId);
    final tasksAsync = ref.watch(taskListProvider(filter));

    return Scaffold(
      appBar: AppBar(
        title: Text(project.name),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: 'Project actions',
            onSelected: (value) => switch (value) {
              'edit' => unawaited(_edit(context)),
              'delete' => unawaited(_delete(context, ref)),
              _ => null,
            },
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined),
                    SizedBox(width: 12),
                    Text('Edit project'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, color: scheme.error),
                    const SizedBox(width: 12),
                    Text(
                      'Delete project',
                      style: TextStyle(color: scheme.error),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _ProjectHeader(project: project, stats: stats),
          ),
          const SliverToBoxAdapter(child: TaskFilterBar()),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          tasksAsync.when(
            loading: () => const SliverToBoxAdapter(
              child: ListSkeleton(count: 6, semanticLabel: 'Loading tasks'),
            ),
            error: (error, _) => SliverToBoxAdapter(
              child: ErrorView(
                message: error is AppException
                    ? error.userMessage
                    : 'The tasks could not be loaded.',
                onRetry: () => ref.invalidate(taskListProvider(filter)),
              ),
            ),
            data: (tasks) {
              if (tasks.isEmpty) {
                return SliverToBoxAdapter(
                  child: filter.isFiltering
                      ? EmptyView(
                          icon: Icons.filter_alt_off_outlined,
                          title: 'No matching tasks',
                          message:
                              'No tasks match the current filters. Adjust or '
                              'clear them to see everything.',
                          actionLabel: 'Clear filters',
                          actionIcon: Icons.filter_alt_off,
                          onAction: () =>
                              ref.read(dueWindowProvider.notifier).clearAll(),
                        )
                      : EmptyView(
                          icon: Icons.task_alt,
                          title: 'No tasks yet',
                          message:
                              'Add the first task to this project — it is '
                              'saved locally and syncs when you connect.',
                          actionLabel: 'New task',
                          onAction: () =>
                              context.push('/tasks/new?project=$projectId'),
                        ),
                );
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return TaskListItem(
                      task: task,
                      onTap: () =>
                          context.push('/tasks/${task.id}/edit', extra: task),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/tasks/new?project=$projectId'),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
    );
  }
}

/// The project header card: name with accent dot and completion progress.
class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.project, required this.stats});

  final Project project;
  final ProjectStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: Color(project.colorValue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    project.name,
                    style: theme.textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              stats.total == 0
                  ? 'No tasks yet'
                  : '${stats.completed} of ${stats.total} tasks done',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (stats.total > 0) ...[
              const SizedBox(height: 8),
              Semantics(
                label: '${stats.completed} of ${stats.total} tasks completed',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(
                    value: stats.progress,
                    minHeight: 8,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
