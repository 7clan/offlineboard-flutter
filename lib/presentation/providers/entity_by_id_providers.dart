import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/project.dart';
import '../../domain/entities/task.dart';
import 'repositories_provider.dart';

/// Watches a single live project by id — the project detail page's source.
///
/// Emits `null` for unknown ids; tombstones (deleted projects) are included
/// so the detail page can show its "project was deleted" state before the
/// user navigates away.
final projectByIdProvider = StreamProvider.family<Project?, String>((ref, id) {
  return ref.watch(projectRepositoryProvider).watchProject(id);
});

/// Watches a single live task by id — the task editor's source when it is
/// opened without the task snapshot (deep links, state restoration).
///
/// Tombstones are included; `null` means unknown id.
final taskByIdProvider = StreamProvider.family<Task?, String>((ref, id) {
  return ref.watch(taskRepositoryProvider).watchTask(id);
});
