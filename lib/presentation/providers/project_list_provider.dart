import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/project.dart';
import 'repositories_provider.dart';

/// Live list of all non-deleted projects (ordered by name), each carrying
/// its derived [Project.syncStatus].
///
/// Re-emits whenever the projects or the sync queue change — no manual
/// refresh anywhere in the UI.
final projectListProvider = StreamProvider<List<Project>>((ref) {
  return ref.watch(projectRepositoryProvider).watchProjects();
});
