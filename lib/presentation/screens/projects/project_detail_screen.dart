import 'package:flutter/material.dart';

/// One project: header, filtered task list, new-task FAB.
class ProjectDetailScreen extends StatelessWidget {
  /// Creates the screen for [projectId].
  const ProjectDetailScreen({super.key, required this.projectId});

  /// The project shown on this page.
  final String projectId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Project')),
      body: const Center(child: Text('Project detail')),
    );
  }
}
