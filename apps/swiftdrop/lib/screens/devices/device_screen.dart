import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/shell.dart';
import '../../design/design.dart';
import '../screen_frame.dart';
import 'device_actions.dart';

/// One device: identity, state in words, actions, and (secondary, collapsed) the
/// technical connection details. The only place transport words appear.
class DeviceScreen extends ConsumerStatefulWidget {
  const DeviceScreen({super.key, required this.deviceId});
  final String deviceId;

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
  bool _details = false;
  bool _connecting = false;
  String? _error;

  Future<void> _connect(Device d) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref.read(deviceDirectoryProvider).connect(d.address!);
    } on TransportException {
      setState(() => _error = 'Couldn’t reach ${d.name}. Check that SwiftDrop is open there and you’re on the same network.');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final d = devices.where((x) => x.id == widget.deviceId).firstOrNull;
    if (d == null) {
      return ScreenFrame(title: 'Device', maxWidth: 560, children: [
        const SizedBox(height: SdSpace.s6),
        const InlineBanner(title: 'This device isn’t in your list any more'),
        const SizedBox(height: SdSpace.s4),
        SecondaryAction(label: 'Back to devices', expand: true, onPressed: () => context.go(Routes.devices)),
      ]);
    }
    final st = deviceStatus(d);
    final live = d.status == DeviceStatus.connected || d.status == DeviceStatus.busy;
    final ep = ref.watch(endpointProvider).value;

    return ScreenFrame(
      title: d.name,
      subtitle: platformLabel(d.platform, d.kind),
      maxWidth: 560,
      children: [
        const SizedBox(height: SdSpace.s6),
        Row(children: [
          DeviceGlyph(kind: d.kind, size: 72, live: live, dim: d.status == DeviceStatus.offline),
          const SizedBox(width: SdSpace.s5),
          StatusPill(label: st.label, icon: st.icon, tone: st.tone),
        ]),
        const SizedBox(height: SdSpace.s6),
        if (_error != null) ...[
          InlineBanner(tone: BannerTone.warning, icon: SdIcons.failed, title: 'Not connected', message: _error),
          const SizedBox(height: SdSpace.s4),
        ],
        PrimaryAction(label: 'Send files', icon: SdIcons.upload, expand: true, onPressed: () => startSend(context, ref, deviceId: d.id)),
        if (!live && d.address != null) ...[
          const SizedBox(height: SdSpace.s2),
          SecondaryAction(label: _connecting ? 'Connecting…' : 'Connect', icon: SdIcons.connect, expand: true, onPressed: _connecting ? null : () => _connect(d)),
        ],
        SettingsGroup(title: 'Device', children: [
          SettingsRow(title: 'Rename', icon: SdIcons.rename, onTap: () => renameDevice(context, ref, d)),
          SettingsRow(
            title: 'Forget this device',
            icon: SdIcons.forget,
            onTap: () async {
              await forgetDevice(context, ref, d);
              if (context.mounted && (ref.read(devicesProvider).value ?? const []).every((x) => x.id != d.id)) context.pop();
            },
          ),
        ]),
        SettingsGroup(
          title: 'Connection details',
          footer: 'SwiftDrop connects devices directly. Files never pass through a server.',
          children: [
            SettingsRow(
              title: _details ? 'Hide details' : 'Show details',
              icon: SdIcons.info,
              onTap: () => setState(() => _details = !_details),
            ),
            if (_details) ...[
              SettingsRow(title: 'Path', detail: switch (d.path?.kind) {
                PathKind.local => 'Local network: both devices have private addresses',
                PathKind.p2p => 'Direct, but the addresses don’t prove a shared network',
                PathKind.relayed => 'Relayed',
                _ => live ? 'Direct' : 'Not connected',
              }),
              SettingsRow(title: 'Transport', detail: live ? 'TCP, several parallel connections' : '--'),
              SettingsRow(title: 'Address', detail: d.address ?? '--'),
              if (ep?.primary != null) SettingsRow(title: 'This device', detail: ep!.primary),
              const SettingsRow(title: 'Encryption', detail: 'Not yet: encrypted, verified pairing arrives in an upcoming update. Use trusted networks until then.'),
            ],
          ],
        ),
      ],
    );
  }
}
