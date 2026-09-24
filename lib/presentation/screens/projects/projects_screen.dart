import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/project.dart';
import '../../providers/project_list_provider.dart';
import '../../providers/project_stats_provider.dart';
import '../../widgets/empty_view.dart';
import '../../widgets/error_view.dart';
import '../../widgets/skeleton.dart';
import '../../widgets/status_icon.dart';
import 'project_editor_dialog.dart';

/// All projects — the home tab.
///
/// Cards show name, task counts, progress and the per-project sync status;
/// the app bar's only action creates a project (everything else lives in
/// the project detail page).
class ProjectsScreen extends ConsumerWidget {
  /// Creates the screen.
  const ProjectsScreen({super.key});

  Future<void> _openEditor(BuildContext context) async {
    await showProjectEditorDialog(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectListProvider);
    final stats = ref.watch(projectStatsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('OfflineBoard'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'New project',
            onPressed: () => unawaited(_openEditor(context)),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: projectsAsync.when(
          loading: () =>
              const ListSkeleton(count: 5, semanticLabel: 'Loading projects'),
          error: (error, _) => ErrorView(
            message: error is AppException
                ? error.userMessage
                : 'Your projects could not be loaded.',
            onRetry: () => ref.invalidate(projectListProvider),
          ),
          data: (projects) {
            if (projects.isEmpty) {
              return EmptyView(
                icon: Icons.folder_open,
                title: 'No projects yet',
                message:
                    'Group your tasks into projects. Everything you create '
                    'works offline and syncs when you connect.',
                actionLabel: 'New project',
                onAction: () => unawaited(_openEditor(context)),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: projects.length,
              itemBuilder: (context, index) {
                final project = projects[index];
                return _ProjectCard(
                  project: project,
                  stats: stats[project.id] ?? ProjectStats.empty,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// One project card.
class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.stats});

  final Project project;
  final ProjectStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: InkWell(
          onTap: () => context.push('/project/${project.id}'),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 10,
                  backgroundColor: Color(project.colorValue),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        stats.total == 0
                            ? 'No tasks yet'
                            : '${stats.completed} of ${stats.total} tasks done',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (stats.total > 0) ...[
                        const SizedBox(height: 8),
                        Semantics(
                          label:
                              '${stats.completed} of ${stats.total} tasks '
                              'completed',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: stats.progress,
                              minHeight: 6,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SyncStatusIcon(status: project.syncStatus),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
