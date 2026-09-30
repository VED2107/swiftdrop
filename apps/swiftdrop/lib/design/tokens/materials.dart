import 'package:flutter/painting.dart';

import 'colors.dart';
import 'radius.dart';

/// The four glass levels. Hierarchy comes from how much each level lifts off the
/// environment, not from glass being everywhere.
enum GlassLevel {
  /// Grouped settings sections, history day groups. Translucent fill, no blur.
  surface,

  /// Device cards, transfer card, file lists. Translucent fill + highlight, no blur.
  card,

  /// Floating tab bar + action dock, desktop sidebar. Real backdrop blur.
  floating,

  /// Incoming transfer, pairing, confirmations. Real backdrop blur over a scrim.
  sheet;

  /// Only these two levels float over scrolling content, so only they pay for a real
  /// backdrop blur. Everything else sits over the soft environment, where a translucent
  /// fill looks the same as a blur and costs nothing.
  bool get blursBackdrop => this == floating || this == sheet;
}

/// User setting (Settings > Appearance > Glass), also forced by Reduce Transparency /
/// high contrast.
enum GlassMode {
  /// Translucency + real blur on floating surfaces and sheets.
  full,

  /// Translucency, no blur anywhere (slower GPUs).
  subtle,

  /// Solid surfaces.
  off,
}

class GlassSpec {
  const GlassSpec({
    required this.fill,
    required this.blurSigma,
    required this.saturation,
    required this.border,
    required this.highlight,
    required this.shadows,
    required this.radius,
  });

  final Color fill;

  /// 0 = no backdrop filter at all.
  final double blurSigma;
  final double saturation;
  final Color border;

  /// Specular top edge; transparent = none.
  final Color highlight;
  final List<BoxShadow> shadows;
  final double radius;
}

abstract final class SdMaterials {
  /// Maximum real backdrop blurs visible at once (floating chrome + one sheet).
  static const blurBudget = 2;

  static GlassSpec spec(GlassLevel level, GlassMode mode) {
    final base = _full[level]!;
    return switch (mode) {
      GlassMode.full => base,
      // Without blur, content scrolling under floating glass needs a denser fill to stay legible.
      GlassMode.subtle => GlassSpec(
          fill: level.blursBackdrop ? _solid[level]!.withValues(alpha: 0.9) : base.fill,
          blurSigma: 0,
          saturation: 1,
          border: base.border,
          highlight: base.highlight,
          shadows: base.shadows,
          radius: base.radius,
        ),
      GlassMode.off => GlassSpec(
          fill: _solid[level]!,
          blurSigma: 0,
          saturation: 1,
          border: SdColors.hairlineStrong,
          highlight: const Color(0x00000000),
          shadows: base.shadows,
          radius: base.radius,
        ),
    };
  }

  static const _solid = {
    GlassLevel.surface: Color(0xFF17171A),
    GlassLevel.card: Color(0xFF1B1B1F),
    GlassLevel.floating: Color(0xFF212126),
    GlassLevel.sheet: Color(0xFF232328),
  };

  static final _full = {
    GlassLevel.surface: const GlassSpec(
      fill: Color(0x0AFFFFFF), // 0.04
      blurSigma: 0,
      saturation: 1,
      border: SdColors.hairline,
      highlight: Color(0x00000000),
      shadows: [],
      radius: SdRadius.row,
    ),
    GlassLevel.card: GlassSpec(
      fill: const Color(0x12FFFFFF), // 0.07
      blurSigma: 0,
      saturation: 1,
      border: SdColors.hairline,
      highlight: const Color(0x1AFFFFFF), // 0.10
      shadows: [BoxShadow(color: SdColors.shadow.withValues(alpha: 0.35), offset: const Offset(0, 12), blurRadius: 32, spreadRadius: -12)],
      radius: SdRadius.card,
    ),
    GlassLevel.floating: GlassSpec(
      fill: const Color(0x1AFFFFFF), // 0.10
      blurSigma: 24,
      saturation: 1.6,
      border: SdColors.hairlineStrong,
      highlight: const Color(0x2EFFFFFF), // 0.18
      shadows: [BoxShadow(color: SdColors.shadow.withValues(alpha: 0.45), offset: const Offset(0, 18), blurRadius: 48, spreadRadius: -16)],
      radius: SdRadius.sheet,
    ),
    GlassLevel.sheet: GlassSpec(
      fill: const Color(0x1FFFFFFF), // 0.12
      blurSigma: 32,
      saturation: 1.8,
      border: SdColors.hairlineStrong,
      highlight: const Color(0x33FFFFFF), // 0.20
      shadows: [BoxShadow(color: SdColors.shadow.withValues(alpha: 0.55), offset: const Offset(0, 30), blurRadius: 80, spreadRadius: -20)],
      radius: SdRadius.sheet,
    ),
  };
}
