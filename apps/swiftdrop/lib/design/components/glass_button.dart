import 'package:flutter/material.dart';

import '../materials/liquid_glass.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
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

    final body = switch (kind) {
      GlassButtonKind.primary => DecoratedBox(
          decoration: ShapeDecoration(
            color: SdColors.red,
            shape: RoundedSuperellipseBorder(borderRadius: SdRadius.all(SdRadius.pill)),
            shadows: [BoxShadow(color: SdColors.redGlow, offset: const Offset(0, 8), blurRadius: 24, spreadRadius: -8)],
          ),
          child: content,
        ),
      GlassButtonKind.secondary => LiquidGlass(level: GlassLevel.card, radius: SdRadius.pill, child: content),
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
