import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'presentation/routes/app_router.dart';

/// Root widget: wires the Material 3 theme and the GoRouter.
///
/// No auth gate — OfflineBoard is local-first, every route is reachable
/// immediately. The router is provided by [appRouterProvider] so screens
/// stay free of navigation wiring.
class OfflineBoardApp extends ConsumerWidget {
  /// Creates the app.
  const OfflineBoardApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'OfflineBoard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
