import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final connected = devices.where((d) => d.status == DeviceStatus.connected || d.status == DeviceStatus.connecting).toList();
    final nearby = devices.where((d) => d.status == DeviceStatus.available).toList();
    final known = devices.where((d) => d.status == DeviceStatus.offline).toList();
    final cardWidth = SdLayout.of(context).isPhone ? null : 208.0;

    Widget grid(List<Device> list) => SdLayout.of(context).isPhone
        ? Column(children: [
            for (final d in list)
              Padding(padding: const EdgeInsets.only(bottom: SdSpace.s3), child: DeviceGlassCard(device: d, onSend: () {})),
          ])
        : Wrap(spacing: SdSpace.s4, runSpacing: SdSpace.s4, children: [
            for (final d in list) DeviceGlassCard(device: d, width: cardWidth, onSend: () {}),
          ]);

    return ScreenFrame(
      title: 'Devices',
      children: [
        if (devices.isEmpty) ...[
          const SizedBox(height: SdSpace.s6),
          const EmptyState(
            icon: SdIcons.devices,
            title: 'No devices yet',
            message: 'Devices you connect to are remembered here, so next time they reconnect without a code.',
          ),
        ],
        if (connected.isNotEmpty) ...[const SectionHeader('Connected'), grid(connected)],
        if (nearby.isNotEmpty) ...[const SectionHeader('Nearby'), grid(nearby)],
        if (known.isNotEmpty) ...[const SectionHeader('Recently used'), grid(known)],
      ],
    );
  }
}
