import 'package:flutter/material.dart';

import '../../../domain/entities/task.dart';

/// Create or edit a task (full page, never a sheet).
class TaskEditorScreen extends StatelessWidget {
  /// Creates the editor in edit mode for [taskId] (with an optional
  /// snapshot passed as route `extra`), or in create mode targeting
  /// [projectId].
  const TaskEditorScreen({super.key, this.taskId, this.projectId, this.initialTask});

  /// The task being edited, or `null` in create mode.
  final String? taskId;

  /// The preset project for a new task, or `null` (the editor then offers
  /// the project dropdown).
  final String? projectId;

  /// Snapshot of the edited task, when available, to prime the form without
  /// waiting for the database stream.
  final Task? initialTask;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Task')),
      body: const Center(child: Text('Task editor')),
    );
  }
}
