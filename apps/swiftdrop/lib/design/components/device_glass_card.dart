import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../icons/sd_icons.dart';
import '../materials/liquid_glass.dart';
import '../motion/appear.dart';
import '../theme/appearance.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'glass_button.dart';
import 'pressable.dart';
import 'status.dart';

/// A device's identity everywhere in the app: the same glyph in cards, sheets, the
/// transfer view and history. A connected device carries a soft red halo.
class DeviceGlyph extends StatelessWidget {
  const DeviceGlyph({super.key, required this.kind, this.size = 44, this.live = false, this.dim = false});
  final DeviceKind kind;
  final double size;

  /// Connected / transferring: the only place a device glyph shows red.
  final bool live;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final reduce = SdAppearance.of(context).reduceMotion;
    return AnimatedContainer(
      duration: reduce ? Duration.zero : SdMotion.page,
      curve: SdMotion.easeOut,
      width: size,
      height: size,
      decoration: ShapeDecoration(
        shape: const CircleBorder(side: BorderSide(color: SdColors.hairlineStrong)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: live ? [const Color(0x33D8322A), const Color(0x14D8322A)] : [const Color(0x1FFFFFFF), const Color(0x0AFFFFFF)],
        ),
        shadows: live ? const [BoxShadow(color: SdColors.redGlow, blurRadius: 18, spreadRadius: -2)] : const [],
      ),
      child: Icon(SdIcons.device(kind), size: size * 0.5, color: dim ? SdColors.text3 : (live ? SdColors.redOnDark : SdColors.text)),
    );
  }
}

/// Words + icon + tone for a device state. Colour is never the only signal.
({String label, IconData? icon, StatusTone tone}) deviceStatus(Device d) => switch (d.status) {
      DeviceStatus.connected => (label: pathLabel(d.path), icon: SdIcons.direct, tone: StatusTone.live),
      DeviceStatus.busy => (label: 'Transferring', icon: SdIcons.direct, tone: StatusTone.live),
      DeviceStatus.connecting => (label: 'Connecting…', icon: null, tone: StatusTone.neutral),
      DeviceStatus.available => (label: 'Ready', icon: null, tone: StatusTone.neutral),
      DeviceStatus.offline => (label: 'Offline', icon: SdIcons.offline, tone: StatusTone.muted),
    };

/// A device as a physical object in the environment: elevated glass that lifts under the
/// pointer, a glyph, its name and platform, its connection state in words, and one action.
class DeviceGlassCard extends StatelessWidget {
  const DeviceGlassCard({
    super.key,
    required this.device,
    this.onSend,
    this.onOpen,
    this.onSecondary,
    this.width,
    this.actionLabel = 'Send',
  });

  final Device device;
  final VoidCallback? onSend;

  /// Tap on the card itself: device details.
  final VoidCallback? onOpen;

  /// Right-click / long-press position: context menu.
  final void Function(Offset globalPosition)? onSecondary;
  final double? width;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final live = device.status == DeviceStatus.connected || device.status == DeviceStatus.busy;
    final offline = device.status == DeviceStatus.offline;
    final platform = platformLabel(device.platform, device.kind);
    final st = deviceStatus(device);

    final info = MergeSemantics(
      child: Semantics(
        label: '${device.name}, $platform, ${st.label.replaceAll(' · ', ', ').toLowerCase()}',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DeviceGlyph(kind: device.kind, live: live, dim: offline),
            const Spacer(),
            if (device.status == DeviceStatus.connecting || device.status == DeviceStatus.busy) _Activity(live: live),
          ]),
          const SizedBox(height: SdSpace.s4),
          Text(device.name,
              style: t.bodyStrong.copyWith(color: offline ? SdColors.text2 : SdColors.text), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(platform, style: t.caption, maxLines: 1),
          const SizedBox(height: SdSpace.s3),
          StatusPill(label: st.label, icon: st.icon, tone: st.tone),
        ]),
      ),
    );

    Widget card = LiquidGlass(
      level: GlassLevel.elevated,
      interactive: true,
      tint: live ? SdColors.red : null,
      padding: const EdgeInsets.all(SdSpace.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onOpen != null)
            Pressable(onPressed: onOpen, semanticLabel: 'Details for ${device.name}', haptic: false, child: info)
          else
            info,
          const SizedBox(height: SdSpace.s4),
          GlassButton(
            label: actionLabel,
            icon: SdIcons.upload,
            kind: live ? GlassButtonKind.primary : GlassButtonKind.secondary,
            compact: true,
            expand: true,
            onPressed: offline && device.address == null ? null : onSend,
          ),
        ],
      ),
    );
    if (onSecondary != null) {
      card = GestureDetector(
        onSecondaryTapUp: (d) => onSecondary!(d.globalPosition),
        onLongPressStart: (d) => onSecondary!(d.globalPosition),
        child: card,
      );
    }
    return Appear(child: SizedBox(width: width, child: card));
  }
}

/// Small breathing marker for "something is happening with this device" (real state only).
class _Activity extends StatefulWidget {
  const _Activity({required this.live});
  final bool live;

  @override
  State<_Activity> createState() => _ActivityState();
}

class _ActivityState extends State<_Activity> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (SdAppearance.of(context).reduceMotion) {
      _c
        ..stop()
        ..value = 0.6;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.live ? SdColors.redOnDark : SdColors.text2;
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(CurvedAnimation(parent: _c, curve: SdMotion.easeInOut)),
      child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    );
  }
}
