import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/shell.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

/// The same device actions everywhere (card menu, device screen).
Future<void> renameDevice(BuildContext context, WidgetRef ref, Device d) async {
  final name = await showRenameSheet(context, title: 'Rename device', current: d.name);
  if (name != null) await ref.read(deviceDirectoryProvider).rename(d.id, name);
}

Future<void> forgetDevice(BuildContext context, WidgetRef ref, Device d) async {
  final ok = await confirmSheet(
    context,
    title: 'Forget ${d.name}?',
    message: 'It disappears from your devices. To send to it again, connect with its address.',
    confirm: 'Forget',
  );
  if (ok) await ref.read(deviceDirectoryProvider).forget(d.id);
}

void showDeviceMenu(BuildContext context, WidgetRef ref, Device d, Offset at) => showGlassMenu(context, at, [
      (label: 'Send files', icon: SdIcons.upload, onTap: () => startSend(context, ref, deviceId: d.id), danger: false),
      (label: 'Details', icon: SdIcons.info, onTap: () => context.push(Routes.device(d.id)), danger: false),
      (label: 'Rename', icon: SdIcons.rename, onTap: () => renameDevice(context, ref, d), danger: false),
      (label: 'Forget', icon: SdIcons.forget, onTap: () => forgetDevice(context, ref, d), danger: true),
    ]);

/// Device cards laid out for the window: a spatial strip on phones, a grid on wider ones.
class DeviceField extends ConsumerWidget {
  const DeviceField({super.key, required this.devices, this.trailing});
  final List<Device> devices;

  /// An extra tile after the devices (e.g. "Connect a device").
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layout = SdLayout.of(context);
    Widget card(Device d, double? width) => DeviceGlassCard(
          device: d,
          width: width,
          onSend: () => startSend(context, ref, deviceId: d.id),
          onOpen: () => context.push(Routes.device(d.id)),
          onSecondary: (at) => showDeviceMenu(context, ref, d, at),
        );
    if (layout.isPhone) {
      // Not clipped at the gutter: scrolled cards run to the screen edge, so the strip
      // reads as objects in space. Height comes from the cards (larger text never clips).
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < devices.length; i++) ...[
            if (i > 0) const SizedBox(width: SdSpace.s3),
            card(devices[i], 172),
          ],
          if (trailing != null) ...[const SizedBox(width: SdSpace.s3), SizedBox(width: 172, child: trailing)],
        ]),
      );
    }
    return Wrap(spacing: SdSpace.s4, runSpacing: SdSpace.s4, children: [
      for (final d in devices) card(d, 212),
      if (trailing != null) SizedBox(width: 212, child: trailing),
    ]);
  }
}

/// The "add a device" tile that sits with the devices.
class ConnectTile extends StatelessWidget {
  const ConnectTile({super.key, this.label = 'Connect a device', this.detail = 'With its address or code'});
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Pressable(
      onPressed: () => context.push(Routes.pair),
      semanticLabel: label,
      haptic: false,
      child: LiquidGlass(
        level: GlassLevel.regular,
        interactive: true,
        padding: const EdgeInsets.all(SdSpace.s4),
        child: SizedBox(
          height: 156,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              height: 44,
              decoration: const ShapeDecoration(shape: CircleBorder(side: BorderSide(color: SdColors.hairlineStrong))),
              child: const Icon(SdIcons.send, color: SdColors.text2),
            ),
            const Spacer(),
            Text(label, style: t.bodyStrong),
            const SizedBox(height: 2),
            Text(detail, style: t.caption),
          ]),
        ),
      ),
    );
  }
}
