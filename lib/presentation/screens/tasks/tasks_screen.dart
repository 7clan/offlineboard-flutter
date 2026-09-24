import 'package:flutter/material.dart';

/// All tasks across projects, with filters and search.
class TasksScreen extends StatelessWidget {
  /// Creates the screen.
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('All tasks')),
      body: const Center(child: Text('Tasks')),
    );
  }
}
