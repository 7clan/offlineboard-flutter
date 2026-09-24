import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Bottom-navigation shell for the three tab branches (projects, tasks,
/// settings).
///
/// A [StatefulShellRoute.indexedStack] keeps each branch's navigator state
/// (scroll position, filter bar) alive while the user switches tabs.
class HomeShell extends StatelessWidget {
  /// Creates the shell.
  const HomeShell({super.key, required this.navigationShell});

  /// The shell's branch controller.
  final StatefulNavigationShell navigationShell;

  static const _destinations = <({IconData icon, IconData selectedIcon, String label})>[
    (icon: Icons.folder_outlined, selectedIcon: Icons.folder, label: 'Projects'),
    (
      icon: Icons.checklist_outlined,
      selectedIcon: Icons.checklist,
      label: 'Tasks',
    ),
    (
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          // Re-tapping the active tab returns to the branch root.
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: [
          for (final (:icon, :selectedIcon, :label) in _destinations)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(selectedIcon),
              label: label,
            ),
        ],
      ),
    );
  }
}
