import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/app.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/shell.dart';
import '../../design/design.dart';
import '../devices/device_actions.dart';
import '../receive/receive_screen.dart';
import '../screen_frame.dart';
import '../transfers/transfer_rows.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final history = ref.watch(historyProvider).value ?? const <TransferRecord>[];
    final transfers = ref.watch(transfersProvider).value ?? const <TransferSnapshot>[];
    final active = transfers.where((t) => !t.phase.isFinished).toList();
    final nearby = devices.where((d) => d.status != DeviceStatus.offline).toList();
    final known = devices.where((d) => d.status == DeviceStatus.offline).take(4).toList();
    final engineError = EngineStatus.of(context);
    final t = context.sdText;

    return ScreenFrame(
      title: 'SwiftDrop',
      subtitle: 'Send anything. Directly.',
      actions: const [HomeActions()],
      panel: const ReceiveCard(compact: true),
      children: [
        if (engineError != null) ...[
          const SizedBox(height: SdSpace.s6),
          const InlineBanner(
            tone: BannerTone.warning,
            icon: SdIcons.failed,
            title: 'Transfers aren’t available right now',
            message: 'SwiftDrop couldn’t start its local connection. Restart the app; if it keeps happening, check that no other program blocks it.',
          ),
        ],
        for (final a in active.take(2)) ...[
          const SizedBox(height: SdSpace.s6),
          TransferGlassCard(transfer: a, onOpen: () => context.push(Routes.transfer(a.transferId))),
        ],
        SectionHeader(
          'Nearby',
          trailing: nearby.isEmpty && known.isEmpty
              ? null
              : GlassButton(label: 'Connect', kind: GlassButtonKind.quiet, compact: true, icon: SdIcons.send, onPressed: () => context.push(Routes.pair)),
        ),
        if (nearby.isEmpty && known.isEmpty)
          EmptyState(
            icon: SdIcons.local,
            title: 'No devices yet',
            message: 'Open SwiftDrop on your other device, on the same Wi-Fi or hotspot, and connect with the address it shows.',
            action: PrimaryAction(label: 'Connect a device', icon: SdIcons.connect, onPressed: () => context.push(Routes.pair)),
          )
        else
          DeviceField(devices: [...nearby, ...known], trailing: const ConnectTile()),
        const SizedBox(height: SdSpace.s6),
        const _PhoneToPhoneCard(),
        SectionHeader(
          'Recent',
          trailing: history.isEmpty
              ? null
              : GlassButton(label: 'See all', kind: GlassButtonKind.quiet, compact: true, onPressed: () => context.go(Routes.transfers)),
        ),
        if (history.isEmpty)
          Text('Nothing sent or received yet.', style: t.body.copyWith(color: SdColors.text2))
        else
          TransferRecordGroup(records: history.take(3).toList()),
      ],
    );
  }
}

/// The core feature, named plainly: two phones, direct, no computer.
class _PhoneToPhoneCard extends StatelessWidget {
  const _PhoneToPhoneCard();

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Pressable(
      onPressed: () => context.push(Routes.phoneToPhone),
      semanticLabel: 'Phone to phone. Direct transfer, no computer needed.',
      haptic: false,
      child: LiquidGlass(
        level: GlassLevel.elevated,
        interactive: true,
        padding: const EdgeInsets.all(SdSpace.s5),
        child: Row(children: [
          const SizedBox(
            width: 100,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              DeviceGlyph(kind: DeviceKind.phone, size: 38),
              Icon(SdIcons.direct, size: 16, color: SdColors.redOnDark),
              DeviceGlyph(kind: DeviceKind.phone, size: 38),
            ]),
          ),
          const SizedBox(width: SdSpace.s4),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Phone to phone', style: t.bodyStrong),
              Text('Direct transfer. No computer needed.', style: t.caption),
            ]),
          ),
          const Icon(SdIcons.chevron, color: SdColors.text3, size: 18),
        ]),
      ),
    );
  }
}
