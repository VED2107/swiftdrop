import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../icons/sd_icons.dart';
import '../tokens/colors.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';

enum StatusTone {
  /// A live link or data moving: the only place status uses red.
  live,
  neutral,
  muted,
}

/// Small state label: icon + words. Colour is never the only signal.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, this.icon, this.tone = StatusTone.neutral});
  final String label;
  final IconData? icon;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      StatusTone.live => SdColors.redOnDark,
      StatusTone.neutral => SdColors.text2,
      StatusTone.muted => SdColors.text3,
    };
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: tone == StatusTone.live ? SdColors.red.withValues(alpha: 0.14) : const Color(0x0DFFFFFF),
        shape: RoundedSuperellipseBorder(borderRadius: SdRadius.all(SdRadius.pill)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SdSpace.s2 + 2, vertical: SdSpace.s1),
        // Narrow cards wrap the label onto a second line rather than clipping it.
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (icon != null) ...[
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 14, color: color)),
            const SizedBox(width: SdSpace.s1 + 2),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.sdText.caption.copyWith(color: color, fontWeight: FontWeight.w500),
            ),
          ),
        ]),
      ),
    );
  }
}

/// What people read about the connection. Technical detail (TCP/WebRTC, addresses)
/// lives only in the device's connection details.
String pathLabel(LinkPath? path) => switch (path?.kind) {
      PathKind.local => 'Direct · Local network',
      PathKind.p2p => 'Direct · P2P',
      PathKind.relayed => 'Relayed',
      _ => 'Direct',
    };

class PathBadge extends StatelessWidget {
  const PathBadge({super.key, required this.path});
  final LinkPath? path;

  @override
  Widget build(BuildContext context) => StatusPill(label: pathLabel(path), icon: SdIcons.local, tone: StatusTone.live);
}
