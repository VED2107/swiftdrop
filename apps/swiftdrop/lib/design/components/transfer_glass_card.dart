import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../icons/sd_icons.dart';
import '../materials/liquid_glass.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'device_glass_card.dart';
import 'pressable.dart';
import 'progress.dart';

/// Words for where a transfer stands. The same strings everywhere (card, screen, history).
String phaseLabel(TransferSnapshot t) {
  final other = t.peerName;
  return switch (t.phase) {
    TransferPhase.awaitingAcceptance => t.role == TransferRole.sending ? 'Waiting for $other to accept' : 'Waiting for you',
    TransferPhase.preparing => 'Preparing',
    TransferPhase.running => t.role == TransferRole.sending ? 'Sending to $other' : 'Receiving from $other',
    TransferPhase.paused => 'Paused',
    TransferPhase.reconnecting => 'Connection interrupted',
    TransferPhase.complete => t.verified ? 'Complete · Verified' : 'Complete',
    TransferPhase.failed => 'Didn’t finish',
    TransferPhase.cancelled => 'Cancelled',
    TransferPhase.declined => '$other declined',
  };
}

/// A live transfer as an object you can open: who, which way, how far, how fast.
class TransferGlassCard extends StatelessWidget {
  const TransferGlassCard({super.key, required this.transfer, this.onOpen});
  final TransferSnapshot transfer;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final s = transfer;
    final live = s.phase == TransferPhase.running;
    final numbers = '${formatBytes(s.bytesDone)} of ${formatBytes(s.bytesTotal)}';
    final right = switch (s.phase) {
      TransferPhase.running when s.speed > 0 => formatRate(s.speed),
      TransferPhase.complete => plural(s.filesTotal, 'file'),
      _ => '${(s.fraction * 100).floor()}%',
    };
    final card = LiquidGlass(
      level: GlassLevel.elevated,
      interactive: onOpen != null,
      tint: live ? SdColors.red : null,
      tintStrength: 0.06,
      padding: const EdgeInsets.all(SdSpace.s4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          DeviceGlyph(kind: s.peerKind, size: 36, live: live),
          const SizedBox(width: SdSpace.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(phaseLabel(s), style: t.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(s.label.isEmpty ? plural(s.filesTotal, 'file') : s.label, style: t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (onOpen != null) const Icon(SdIcons.chevron, size: 18, color: SdColors.text3),
        ]),
        const SizedBox(height: SdSpace.s4),
        ProgressGlass(value: s.fraction, live: live, semanticsLabel: phaseLabel(s)),
        const SizedBox(height: SdSpace.s2),
        Row(children: [
          Expanded(child: Text(numbers, style: t.numericSmall)),
          Text(right, style: t.numericSmall.copyWith(color: live ? SdColors.text : SdColors.text2)),
        ]),
      ]),
    );
    if (onOpen == null) return card;
    return Pressable(onPressed: onOpen, semanticLabel: '${phaseLabel(s)}, $numbers', haptic: false, child: card);
  }
}
