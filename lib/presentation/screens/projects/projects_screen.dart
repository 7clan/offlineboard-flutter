import 'package:flutter/material.dart';

/// All projects — the home tab.
class ProjectsScreen extends StatelessWidget {
  /// Creates the screen.
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OfflineBoard')),
      body: const Center(child: Text('Projects')),
    );
  }
}
