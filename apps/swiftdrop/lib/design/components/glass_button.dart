import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'pressable.dart';

enum GlassButtonKind {
  /// The one action that moves the flow forward. Solid red: never glass, so the primary
  /// action reads instantly over any background.
  primary,

  /// Equal-weight alternative (Receive next to Send). Card glass.
  secondary,

  /// Low-emphasis (Cancel, Decline in some contexts). Text only.
  quiet,
}

class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = GlassButtonKind.secondary,
    this.icon,
    this.expand = false,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final GlassButtonKind kind;
  final IconData? icon;

  /// Fill the available width.
  final bool expand;

  /// 40 pt tall instead of 52, for cards and rows.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = context.sdText.label;
    // A disabled primary loses its red: faded red reads as broken, neutral reads as "not yet".
    final kind = onPressed == null && this.kind == GlassButtonKind.primary ? GlassButtonKind.secondary : this.kind;
    final fg = switch (kind) {
      GlassButtonKind.primary => SdColors.onRed,
      GlassButtonKind.secondary => SdColors.text,
      GlassButtonKind.quiet => SdColors.text2,
    };
    final height = compact ? 40.0 : 52.0;
    final content = SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? SdSpace.s4 : SdSpace.s6),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, size: compact ? 18 : 20, color: fg), SizedBox(width: SdSpace.s2)],
            Flexible(child: Text(label, style: text.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );

    // Clay console: primary and secondary are molded keys with a skirt (their thickness)
    // and real travel, pressed by [Pressable]'s squish. Quiet stays plain text.
    final r = SdRadius.all(height * 0.32);
    final body = switch (kind) {
      GlassButtonKind.primary => _ClayFace(
          radius: r,
          top: const Color(0xFFF04A3E),
          bottom: const Color(0xFFB3241C),
          skirt: const Color(0xFF7A140F),
          rim: const Color(0x47FFFFFF),
          glow: SdColors.red,
          child: content,
        ),
      GlassButtonKind.secondary => _ClayFace(
          radius: r,
          top: const Color(0xFF352E34),
          bottom: const Color(0xFF2A2429),
          skirt: const Color(0xFF110E11),
          rim: const Color(0x1AFFFFFF),
          child: content,
        ),
      GlassButtonKind.quiet => content,
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SdSpace.touch, minWidth: SdSpace.touch),
      child: Pressable(onPressed: onPressed, semanticLabel: label, focusRadius: SdRadius.pill, child: ExcludeSemantics(child: body)),
    );
  }
}

class PrimaryAction extends GlassButton {
  const PrimaryAction({super.key, required super.label, required super.onPressed, super.icon, super.expand, super.compact})
      : super(kind: GlassButtonKind.primary);
}

class SecondaryAction extends GlassButton {
  const SecondaryAction({super.key, required super.label, required super.onPressed, super.icon, super.expand, super.compact})
      : super(kind: GlassButtonKind.secondary);
}

/// A molded key face sitting on its skirt: 3 pt of visible thickness below, a lit top
/// rim, a soft drop. The press squish comes from [Pressable] (scale 0.97).
class _ClayFace extends StatelessWidget {
  const _ClayFace({required this.radius, required this.top, required this.bottom, required this.skirt, required this.rim, required this.child, this.glow});
  final BorderRadius radius;
  final Color top;
  final Color bottom;
  final Color skirt;
  final Color rim;
  final Color? glow;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]),
          border: Border(top: BorderSide(color: rim)),
          boxShadow: [
            BoxShadow(color: skirt, offset: const Offset(0, 3)),
            BoxShadow(color: (glow ?? const Color(0xFF000000)).withValues(alpha: glow == null ? 0.55 : 0.4), offset: const Offset(0, 10), blurRadius: 22, spreadRadius: -8),
          ],
        ),
        child: child,
      );
}
