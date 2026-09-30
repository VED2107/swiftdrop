import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../screens/devices/device_screen.dart';
import '../screens/devices/devices_screen.dart';
import '../screens/gallery/gallery_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/pair/pair_screen.dart';
import '../screens/receive/receive_screen.dart';
import '../screens/send/send_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../screens/transfer/transfer_screen.dart';
import '../screens/transfers/transfers_screen.dart';
import 'shell.dart';

abstract final class Routes {
  static const home = '/';
  static const transfers = '/transfers';
  static const devices = '/devices';
  static const settings = '/settings';

  static const send = '/send';
  static const receive = '/receive';
  static const pair = '/pair';

  /// Phone to phone: the pairing flow framed as the direct phone-to-phone feature.
  static const phoneToPhone = '/pair?p2p=1';
  static String transfer(String id) => '/transfer/$id';
  static String device(String id) => '/device/${Uri.encodeComponent(id)}';

  /// Design-system gallery, debug builds only.
  static const gallery = '/gallery';
}

/// Sections are a stateful shell (each keeps its scroll position). Flows (send, receive,
/// pair, transfer, device) are pushed above it.
GoRouter buildRouter({String initialLocation = Routes.home}) => GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: initialLocation,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => AppShell(shell: shell),
          branches: [
            StatefulShellBranch(routes: [GoRoute(path: Routes.home, builder: (_, _) => const HomeScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: Routes.transfers, builder: (_, _) => const TransfersScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: Routes.devices, builder: (_, _) => const DevicesScreen())]),
            StatefulShellBranch(routes: [GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen())]),
          ],
        ),
        GoRoute(path: Routes.send, builder: (_, _) => const FlowFrame(child: SendScreen())),
        GoRoute(path: Routes.receive, builder: (_, _) => const FlowFrame(child: ReceiveScreen())),
        GoRoute(
          path: Routes.pair,
          builder: (_, s) => FlowFrame(child: PairScreen(phoneToPhone: s.uri.queryParameters['p2p'] == '1')),
        ),
        GoRoute(path: '/transfer/:id', builder: (_, s) => FlowFrame(child: TransferScreen(transferId: s.pathParameters['id']!))),
        GoRoute(path: '/device/:id', builder: (_, s) => FlowFrame(child: DeviceScreen(deviceId: Uri.decodeComponent(s.pathParameters['id']!)))),
        if (kDebugMode) GoRoute(path: Routes.gallery, builder: (_, _) => const FlowFrame(child: GalleryScreen())),
      ],
      errorBuilder: (_, _) => const SizedBox.shrink(),
    );
