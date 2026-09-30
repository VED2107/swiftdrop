import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../design/design.dart';

const destinations = [
  NavDestination(label: 'Home', icon: SdIcons.home, selectedIcon: SdIcons.homeSelected, shortcut: 'Ctrl 1'),
  NavDestination(label: 'Transfers', icon: SdIcons.transfers, selectedIcon: SdIcons.transfersSelected, shortcut: 'Ctrl 2'),
  NavDestination(label: 'Devices', icon: SdIcons.devices, selectedIcon: SdIcons.devicesSelected, shortcut: 'Ctrl 3'),
  NavDestination(label: 'Settings', icon: SdIcons.settings, selectedIcon: SdIcons.settingsSelected, shortcut: 'Ctrl 4'),
];

/// Height the phone's floating panel covers, so scroll content can pass under the glass
/// and still end above it.
double phoneChromeHeight(BuildContext context, {required bool withDock}) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  const tabs = 52.0 + SdSpace.s2 * 2;
  const dock = 52.0 + SdSpace.s1 + SdSpace.s2;
  return tabs + (withDock ? dock : 0) + (bottom > 0 ? bottom : SdSpace.s3) + SdSpace.s3;
}

/// The app frame: navigation by window class, section shortcuts, and the phone dock.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell, required this.dock});

  final StatefulNavigationShell shell;

  /// Primary actions (Send / Receive) shown in the phone panel on Home.
  final Widget dock;

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final layout = SdLayout.of(context);
    final shortcuts = <ShortcutActivator, VoidCallback>{
      for (var i = 0; i < destinations.length; i++) ...{
        SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: true): () => _go(i),
        SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), meta: true): () => _go(i),
      },
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () => _go(3),
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => _go(3),
    };

    final Widget frame;
    if (layout.isPhone) {
      final withDock = shell.currentIndex == 0;
      final mq = MediaQuery.of(context);
      frame = Stack(children: [
        Positioned.fill(
          child: MediaQuery(
            data: mq.copyWith(padding: mq.padding.copyWith(bottom: phoneChromeHeight(context, withDock: withDock))),
            child: shell,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: GlassNavigation(
            destinations: destinations,
            selected: shell.currentIndex,
            onSelect: _go,
            dock: withDock ? dock : null,
          ),
        ),
      ]);
    } else {
      frame = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SafeArea(
          right: false,
          child: GlassNavigation(
            destinations: destinations,
            selected: shell.currentIndex,
            onSelect: _go,
            header: Text('SwiftDrop', style: context.sdText.title),
          ),
        ),
        Expanded(child: shell),
      ]);
    }

    return CallbackShortcuts(bindings: shortcuts, child: Focus(autofocus: true, child: frame));
  }
}
