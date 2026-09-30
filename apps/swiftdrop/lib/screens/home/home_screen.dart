import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../design/design.dart';
import '../screen_frame.dart';
import '../transfers/transfer_rows.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final history = ref.watch(historyProvider).value ?? const <TransferRecord>[];
    final nearby = devices.where((d) => d.status != DeviceStatus.offline).toList();

    return ScreenFrame(
      title: 'SwiftDrop',
      actions: const [HomeActions()],
      children: [
        const SectionHeader('Nearby'),
        if (nearby.isEmpty) const _NobodyNearby() else _DeviceStrip(devices: nearby),
        const SectionHeader('Recent'),
        if (history.isEmpty)
          Text('Nothing sent or received yet.', style: context.sdText.body.copyWith(color: SdColors.text2))
        else
          TransferRecordGroup(records: history.take(3).toList()),
      ],
    );
  }
}

/// Send / Receive. Equal access: Send is primary, Receive is never hidden.
/// Both open flows that arrive with the engine (Phase 4); until then they're disabled.
class HomeActions extends StatelessWidget {
  const HomeActions({super.key, this.inDock = false});
  final bool inDock;

  @override
  Widget build(BuildContext context) {
    final send = PrimaryAction(label: 'Send files', icon: SdIcons.send, expand: inDock, onPressed: null);
    final receive = SecondaryAction(label: 'Receive', icon: SdIcons.receive, expand: inDock, onPressed: null);
    if (!inDock) return Row(mainAxisSize: MainAxisSize.min, children: [send, const SizedBox(width: SdSpace.s3), receive]);
    return Row(children: [Expanded(flex: 3, child: send), const SizedBox(width: SdSpace.s2), Expanded(flex: 2, child: receive)]);
  }
}

class _DeviceStrip extends StatelessWidget {
  const _DeviceStrip({required this.devices});
  final List<Device> devices;

  @override
  Widget build(BuildContext context) {
    final layout = SdLayout.of(context);
    if (layout.isPhone) {
      // Horizontal strip that isn't clipped at the gutter, so scrolled cards run to the
      // screen edge and the strip reads as spatial. Height comes from the cards, so larger
      // text never clips them.
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < devices.length; i++) ...[
            if (i > 0) const SizedBox(width: SdSpace.s3),
            DeviceGlassCard(device: devices[i], width: 172, onSend: () {}),
          ],
        ]),
      );
    }
    return Wrap(
      spacing: SdSpace.s4,
      runSpacing: SdSpace.s4,
      children: [for (final d in devices) DeviceGlassCard(device: d, width: 208, onSend: () {})],
    );
  }
}

class _NobodyNearby extends StatelessWidget {
  const _NobodyNearby();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: SdIcons.local,
      title: 'No devices nearby yet',
      message: 'Devices show up here when SwiftDrop is open on them and they share your Wi-Fi or hotspot.',
      action: SecondaryAction(label: 'Connect with a code', icon: SdIcons.qr, onPressed: null),
    );
  }
}
