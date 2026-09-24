import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/task.dart';
import '../screens/home_shell.dart';
import '../screens/projects/project_detail_screen.dart';
import '../screens/projects/projects_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/tasks/task_editor_screen.dart';
import '../screens/tasks/tasks_screen.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Declarative navigation.
///
/// Three tab branches live under a [StatefulShellRoute.indexedStack] (each
/// tab keeps its scroll position and filter state); the project detail and
/// task editor pages cover the whole screen from the root navigator so they
/// sit above the bottom navigation bar.
///
/// There is no auth gate — OfflineBoard is local-first, so every route is
/// reachable immediately.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/project/:id',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) =>
            ProjectDetailScreen(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/tasks/new',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) =>
            TaskEditorScreen(projectId: state.uri.queryParameters['project']),
      ),
      GoRoute(
        path: '/tasks/:id/edit',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => TaskEditorScreen(
          taskId: state.pathParameters['id']!,
          initialTask: state.extra is Task ? state.extra! as Task : null,
        ),
      ),
      StatefulShellRoute.indexedStack(
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const ProjectsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/tasks',
                builder: (context, state) => const TasksScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
