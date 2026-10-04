import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../design/design.dart';
import '../screens/receive/incoming_sheet.dart';
import '../screens/receive/join_sheet.dart';
import 'picking.dart';
import 'providers.dart';
import 'router.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

const destinations = [
  NavDestination(label: 'Home', icon: SdIcons.home, selectedIcon: SdIcons.homeSelected, shortcut: 'Ctrl 1'),
  NavDestination(label: 'Transfers', icon: SdIcons.transfers, selectedIcon: SdIcons.transfersSelected, shortcut: 'Ctrl 2'),
  NavDestination(label: 'Devices', icon: SdIcons.devices, selectedIcon: SdIcons.devicesSelected, shortcut: 'Ctrl 3'),
  NavDestination(label: 'Settings', icon: SdIcons.settings, selectedIcon: SdIcons.settingsSelected, shortcut: 'Ctrl 4'),
];

bool get _desktop => !(Platform.isAndroid || Platform.isIOS);

/// Height the phone's floating panel covers, so scroll content can pass under the glass
/// and still end above it.
double phoneChromeHeight(BuildContext context, {required bool withDock}) {
  final bottom = MediaQuery.paddingOf(context).bottom;
  const tabs = 56.0 + SdSpace.s2 * 2;
  const dock = 52.0 + SdSpace.s1 + SdSpace.s2;
  return tabs + (withDock ? dock : 0) + (bottom > 0 ? bottom : SdSpace.s3) + SdSpace.s3;
}

/// Starts the send flow: pick files (unless some are already selected), then review.
Future<void> startSend(BuildContext context, WidgetRef ref, {String? deviceId, bool folder = false}) async {
  final sel = ref.read(selectionProvider.notifier);
  if (deviceId != null) sel.target(deviceId);
  if (ref.read(selectionProvider).isEmpty) {
    final picked = folder ? await pickFolder() : await pickFiles();
    if (picked.isEmpty) return;
    sel.add(picked);
  }
  if (context.mounted) context.push(Routes.send);
}

/// The app frame: navigation shaped by the window, and the phone's action dock.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  void _go(int i) => shell.goBranch(i, initialLocation: i == shell.currentIndex);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      final mq = MediaQuery.of(context);
      frame = Stack(children: [
        Positioned.fill(
          child: MediaQuery(
            data: mq.copyWith(padding: mq.padding.copyWith(bottom: phoneChromeHeight(context, withDock: false))),
            child: _TabSwitch(index: shell.currentIndex, child: shell),
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
            header: Row(children: [
              const SwiftMark(size: 30),
              const SizedBox(width: SdSpace.s3),
              // The rail is 192 wide at its narrowest: the wordmark scales down to fit.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text('SwiftDrop', style: context.sdText.title, maxLines: 1),
                ),
              ),
            ]),
            footer: const _SidebarFooter(),
          ),
        ),
        Expanded(child: _TabSwitch(index: shell.currentIndex, child: shell)),
      ]);
    }
    return CallbackShortcuts(bindings: shortcuts, child: Focus(autofocus: true, child: frame));
  }
}

/// Section change: the new section fades up 8 pt in 220 ms (ease-out), so the eye reads it
/// as "somewhere else" without a slide that implies direction. The section tree is never
/// rebuilt (each keeps its scroll position). Keyboard switches (Ctrl 1-4) skip it.
class _TabSwitch extends StatefulWidget {
  const _TabSwitch({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_TabSwitch> createState() => _TabSwitchState();
}

class _TabSwitchState extends State<_TabSwitch> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: SdMotion.small, value: 1);

  @override
  void didUpdateWidget(_TabSwitch old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    final keyboard = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    if (keyboard) return;
    _c.duration = SdAppearance.of(context).reduceMotion ? SdMotion.reduced : SdMotion.small;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: SdMotion.easeOut);
    final reduce = SdAppearance.of(context).reduceMotion;
    return FadeTransition(
      opacity: Tween(begin: 0.0, end: 1.0).animate(curve),
      child: reduce
          ? widget.child
          : AnimatedBuilder(
              animation: curve,
              builder: (_, child) => Transform.translate(offset: Offset(0, 8 * (1 - curve.value)), child: child),
              child: widget.child,
            ),
    );
  }
}

/// Send / Receive. Send is the dominant action; Receive is never hidden.
class HomeActions extends ConsumerWidget {
  const HomeActions({super.key, this.inDock = false});
  final bool inDock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final send = PrimaryAction(label: 'Send files', icon: SdIcons.send, expand: inDock, onPressed: () => startSend(context, ref));
    final receive = SecondaryAction(label: 'Receive', icon: SdIcons.receive, expand: inDock, onPressed: () => context.push(Routes.receive));
    if (!inDock) return Row(mainAxisSize: MainAxisSize.min, children: [receive, const SizedBox(width: SdSpace.s3), send]);
    return Row(children: [Expanded(flex: 3, child: send), const SizedBox(width: SdSpace.s2), Expanded(flex: 2, child: receive)]);
  }
}

class _SidebarFooter extends ConsumerWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.sdText;
    final ep = ref.watch(endpointProvider).value;
    if (ep == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('This device', style: t.micro),
      Text(ep.name, style: t.caption.copyWith(color: SdColors.text), maxLines: 1, overflow: TextOverflow.ellipsis),
      if (ep.primary != null) Text(ep.primary!, style: t.numericSmall),
    ]);
  }
}

/// Layer above every route: drop files anywhere (desktop), incoming-transfer requests as a
/// system-style sheet wherever you are, and Ctrl/Cmd+O to send.
class GlobalLayer extends ConsumerStatefulWidget {
  const GlobalLayer({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<GlobalLayer> createState() => _GlobalLayerState();
}

class _GlobalLayerState extends ConsumerState<GlobalLayer> {
  bool _dragging = false;
  final _shown = <String>{};
  bool _primed = false;

  BuildContext? get _nav => rootNavigatorKey.currentContext;

  Future<void> _onDrop(List<String> paths) async {
    setState(() => _dragging = false);
    final items = await describePaths(paths);
    if (items.isEmpty) return;
    ref.read(selectionProvider.notifier).add(items);
    final nav = _nav;
    if (nav != null && nav.mounted) GoRouter.of(nav).push(Routes.send);
  }

  void _showOffer(IncomingOffer offer) {
    final nav = _nav;
    if (nav == null || !_shown.add(offer.transferId)) return;
    showGlassSheet<void>(nav, dismissible: false, semanticLabel: 'Incoming transfer', builder: (_) => IncomingSheet(offer: offer));
  }

  void _showJoin(BrowserJoin join) {
    final nav = _nav;
    if (nav == null || !_shown.add('join:${join.id}')) return;
    showGlassSheet<void>(nav, dismissible: false, semanticLabel: 'Phone wants to connect', builder: (_) => JoinSheet(join: join));
  }

  /// A transfer that arrives without a question (an iPhone uploading through the browser
  /// page) opens its live screen, so this device shows what it's receiving the moment
  /// bytes move. Own sends and accepted offers navigate by themselves; transfers already
  /// running when the app started don't pop up.
  void _onTransfers(List<TransferSnapshot> list) {
    if (!_primed) {
      _primed = true;
      _shown.addAll(list.map((t) => 'tr:${t.transferId}'));
      return;
    }
    for (final t in list) {
      if (t.role != TransferRole.receiving || t.phase.isFinished || t.phase == TransferPhase.awaitingAcceptance) continue;
      if (!_shown.add('tr:${t.transferId}') || _shown.contains(t.transferId)) continue;
      final nav = _nav;
      if (nav == null || !nav.mounted) continue;
      final router = GoRouter.of(nav);
      if (router.routerDelegate.currentConfiguration.uri.path == Routes.transfer(t.transferId)) continue;
      router.push(Routes.transfer(t.transferId));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(transfersProvider, (_, next) {
      final list = next.value;
      if (list != null) _onTransfers(list);
    });
    ref.listen(incomingProvider, (_, next) {
      for (final o in next.value ?? const <IncomingOffer>[]) {
        _showOffer(o);
      }
    });
    ref.listen(browserJoinsProvider, (_, next) {
      for (final j in next.value ?? const <BrowserJoin>[]) {
        _showJoin(j);
      }
    });
    Widget child = widget.child;
    child = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () {
          final nav = _nav;
          if (nav != null) startSend(nav, ref);
        },
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true): () {
          final nav = _nav;
          if (nav != null) startSend(nav, ref);
        },
      },
      child: child,
    );
    if (!_desktop) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (d) => _onDrop([for (final f in d.files) f.path]),
      child: Stack(children: [child, if (_dragging) const Positioned.fill(child: _DropOverlay())]),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return IgnorePointer(
      child: ColoredBox(
        color: SdColors.scrim,
        child: Center(
          child: LiquidGlass(
            level: GlassLevel.sheet,
            tint: SdColors.red,
            padding: const EdgeInsets.symmetric(horizontal: SdSpace.s12, vertical: SdSpace.s10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(SdIcons.drop, size: 40, color: SdColors.redOnDark),
              const SizedBox(height: SdSpace.s4),
              Text('Drop to send', style: t.title),
              const SizedBox(height: SdSpace.s1),
              Text('Files and folders, sent directly', style: t.caption),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Frame for pushed flows: a back control, Escape to go back, a readable width on large
/// windows. Keyboard-initiated navigation doesn't animate.
class FlowFrame extends StatelessWidget {
  const FlowFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    void back() => context.canPop() ? context.pop() : context.go(Routes.home);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): back},
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: SafeArea(
            bottom: false,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(SdSpace.s3, SdSpace.s2, SdSpace.s3, 0),
                child: Row(children: [
                  GlassButton(label: 'Back', icon: SdIcons.back, kind: GlassButtonKind.quiet, compact: true, onPressed: back),
                  const Spacer(),
                ]),
              ),
              Expanded(child: child),
            ]),
          ),
        ),
      ),
    );
  }
}
