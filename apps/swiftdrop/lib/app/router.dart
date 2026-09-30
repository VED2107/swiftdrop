import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../screens/devices/devices_screen.dart';
import '../screens/gallery/gallery_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/transfers/transfers_screen.dart';
import 'shell.dart';

abstract final class Routes {
  static const home = '/';
  static const transfers = '/transfers';
  static const devices = '/devices';
  static const settings = '/settings';

  /// Design-system gallery, debug builds only.
  static const gallery = '/gallery';
}

/// Sections are a stateful shell (each keeps its scroll position); flows (send, pair,
/// transfer) will be pushed above it in later phases.
GoRouter buildRouter({String initialLocation = Routes.home}) => GoRouter(
      initialLocation: initialLocation,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => AppShell(shell: shell, dock: const HomeActions(inDock: true)),
          branches: [
            StatefulShellBranch(routes: [GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: Routes.transfers, builder: (_, _) => const TransfersScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: Routes.devices, builder: (_, _) => const DevicesScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen())]),
          ],
        ),
        if (kDebugMode) GoRoute(path: Routes.gallery, builder: (_, _) => const GalleryScreen()),
      ],
      errorBuilder: (_, _) => const SizedBox.shrink(),
    );
