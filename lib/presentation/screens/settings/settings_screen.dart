import 'package:flutter/material.dart';

/// Sync controls, offline simulation and about.
class SettingsScreen extends StatelessWidget {
  /// Creates the screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const Center(child: Text('Settings')),
    );
  }
}
