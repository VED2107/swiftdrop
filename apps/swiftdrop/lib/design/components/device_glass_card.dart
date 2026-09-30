import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../icons/sd_icons.dart';
import '../materials/liquid_glass.dart';
import '../motion/appear.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'glass_button.dart';
import 'status.dart';

/// A nearby or known device. Card glass (no blur); a connected device carries a faint red
/// tint and its path badge, so "which one am I connected to" reads at a glance.
class DeviceGlassCard extends StatelessWidget {
  const DeviceGlassCard({super.key, required this.device, this.onSend, this.onOpen, this.width});

  final Device device;
  final VoidCallback? onSend;
  final VoidCallback? onOpen;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final connected = device.status == DeviceStatus.connected;
    final offline = device.status == DeviceStatus.offline;
    final platform = platformLabel(device.platform, device.kind);

    final status = switch (device.status) {
      DeviceStatus.connected => PathBadge(path: device.path),
      DeviceStatus.connecting => const StatusPill(label: 'Connecting…'),
      DeviceStatus.available => const StatusPill(label: 'Available'),
      DeviceStatus.offline => const StatusPill(label: 'Offline', icon: SdIcons.offline, tone: StatusTone.muted),
    };

    return Appear(
      child: SizedBox(
        width: width,
        child: LiquidGlass(
          level: GlassLevel.card,
          tint: connected ? SdColors.red : null,
          padding: const EdgeInsets.all(SdSpace.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              MergeSemantics(
                child: Semantics(
                  label: '${device.name}, $platform, ${_spoken(device)}',
                  excludeSemantics: true,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _DeviceGlyph(kind: device.kind, dim: offline),
                    const SizedBox(height: SdSpace.s4),
                    Text(device.name,
                        style: t.bodyStrong.copyWith(color: offline ? SdColors.text2 : SdColors.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(platform, style: t.caption, maxLines: 1),
                    const SizedBox(height: SdSpace.s3),
                    status,
                  ]),
                ),
              ),
              const SizedBox(height: SdSpace.s4),
              GlassButton(
                label: 'Send',
                kind: connected ? GlassButtonKind.primary : GlassButtonKind.secondary,
                compact: true,
                expand: true,
                onPressed: offline ? null : onSend,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _spoken(Device d) => switch (d.status) {
        DeviceStatus.connected => 'connected, ${pathLabel(d.path).replaceAll(' · ', ' on ').toLowerCase()}',
        DeviceStatus.connecting => 'connecting',
        DeviceStatus.available => 'available',
        DeviceStatus.offline => 'offline',
      };
}

class _DeviceGlyph extends StatelessWidget {
  const _DeviceGlyph({required this.kind, required this.dim});
  final DeviceKind kind;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const ShapeDecoration(color: Color(0x14FFFFFF), shape: CircleBorder()),
      child: Padding(
        padding: const EdgeInsets.all(SdSpace.s2 + 2),
        child: Icon(SdIcons.device(kind), size: 22, color: dim ? SdColors.text3 : SdColors.text),
      ),
    );
  }
}
