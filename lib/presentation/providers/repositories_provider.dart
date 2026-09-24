import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/repositories/project_repository.dart';
import '../../domain/repositories/task_repository.dart';
import '../../data/repositories/project_repository_impl.dart';
import '../../data/repositories/task_repository_impl.dart';
import 'core_providers.dart';
import 'database_provider.dart';
import 'sync_controller.dart';

/// The local-first project repository.
///
/// Mutations fire the sync controller (fire-and-forget) through the
/// repository's injected `syncTrigger`, so local writes become server
/// pushes opportunistically.
final projectRepositoryProvider = Provider<ProjectRepository>((ref) {
  return ProjectRepositoryImpl(
    db: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
    idGenerator: ref.watch(idGeneratorProvider),
    config: ref.watch(appConfigProvider),
    syncTrigger: () => ref.read(syncControllerProvider.notifier).syncNow(),
  );
});

/// The local-first task repository.
final taskRepositoryProvider = Provider<TaskRepository>((ref) {
  return TaskRepositoryImpl(
    db: ref.watch(databaseProvider),
    clock: ref.watch(clockProvider),
    idGenerator: ref.watch(idGeneratorProvider),
    config: ref.watch(appConfigProvider),
    syncTrigger: () => ref.read(syncControllerProvider.notifier).syncNow(),
  );
});
