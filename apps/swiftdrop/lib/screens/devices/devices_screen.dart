import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/design.dart';
import '../screen_frame.dart';
import 'device_actions.dart';

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final connected = devices.where((d) => d.status == DeviceStatus.connected || d.status == DeviceStatus.busy || d.status == DeviceStatus.connecting).toList();
    final nearby = devices.where((d) => d.status == DeviceStatus.available).toList();
    final recent = devices.where((d) => d.status == DeviceStatus.offline).toList()
      ..sort((a, b) => (b.lastUsed ?? DateTime(0)).compareTo(a.lastUsed ?? DateTime(0)));

    return ScreenFrame(
      title: 'Devices',
      actions: [SecondaryAction(label: 'Connect a device', icon: SdIcons.connect, onPressed: () => context.push(Routes.pair))],
      children: [
        if (devices.isEmpty) ...[
          const SizedBox(height: SdSpace.s6),
          EmptyState(
            icon: SdIcons.devices,
            title: 'No devices yet',
            message: 'Devices you connect to are remembered here, so next time they reconnect with a tap.',
            action: PrimaryAction(label: 'Connect a device', icon: SdIcons.connect, onPressed: () => context.push(Routes.pair)),
          ),
        ],
        if (connected.isNotEmpty) ...[const SectionHeader('Connected'), DeviceField(devices: connected)],
        if (nearby.isNotEmpty) ...[const SectionHeader('Nearby'), DeviceField(devices: nearby)],
        if (recent.isNotEmpty) ...[const SectionHeader('Recently used'), DeviceField(devices: recent)],
      ],
    );
  }
}
