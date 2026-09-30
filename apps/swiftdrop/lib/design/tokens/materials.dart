import 'package:flutter/painting.dart';

import 'colors.dart';
import 'radius.dart';

/// The four Liquid Glass levels. Following Apple's principle that glass belongs to the
/// control layer floating above content, only the two floating levels sample what's
/// behind them for real; content-level surfaces are translucent material over a soft
/// environment, where a blur would look identical and cost a backdrop pass each.
enum GlassLevel {
  /// Grouped content: settings groups, history days. Quiet, flat, no blur.
  regular,

  /// Objects you act on: device cards, the transfer card, file tiles. A lit top edge, a
  /// tinted shadow, and a physical response to hover and press. No blur.
  elevated,

  /// Floating controls over scrolling content: tab bar + action dock, sidebar, send dock.
  /// Real backdrop blur + saturation.
  floating,

  /// Modal requests: incoming transfer, pairing, confirmations. Strongest blur, over a scrim.
  sheet;

  bool get blursBackdrop => this == floating || this == sheet;
}

/// User setting (Settings > Appearance > Glass); forced to [off] by high contrast.
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
    required this.fillTop,
    required this.fillBottom,
    required this.blurSigma,
    required this.saturation,
    required this.border,
    required this.highlight,
    required this.shadows,
    required this.radius,
    this.hoverLift = 0,
  });

  /// Fill is a faint vertical gradient: light from above, as real glass catches it.
  final Color fillTop;
  final Color fillBottom;

  /// 0 = no backdrop filter at all.
  final double blurSigma;
  final double saturation;
  final Color border;

  /// Specular top edge; transparent = none.
  final Color highlight;
  final List<BoxShadow> shadows;
  final double radius;

  /// Points an interactive surface rises on hover (desktop) / sinks on press.
  final double hoverLift;
}

abstract final class SdMaterials {
  /// Maximum real backdrop blurs visible at once (floating chrome + one sheet).
  static const blurBudget = 2;

  static GlassSpec spec(GlassLevel level, GlassMode mode) {
    final base = _full[level]!;
    return switch (mode) {
      GlassMode.full => base,
      // Without blur, content scrolling under floating glass needs a denser fill.
      GlassMode.subtle => GlassSpec(
          fillTop: level.blursBackdrop ? _solid[level]!.withValues(alpha: 0.92) : base.fillTop,
          fillBottom: level.blursBackdrop ? _solid[level]!.withValues(alpha: 0.92) : base.fillBottom,
          blurSigma: 0,
          saturation: 1,
          border: base.border,
          highlight: base.highlight,
          shadows: base.shadows,
          radius: base.radius,
          hoverLift: base.hoverLift,
        ),
      GlassMode.off => GlassSpec(
          fillTop: _solid[level]!,
          fillBottom: _solid[level]!,
          blurSigma: 0,
          saturation: 1,
          border: SdColors.hairlineStrong,
          highlight: const Color(0x00000000),
          shadows: base.shadows,
          radius: base.radius,
          hoverLift: base.hoverLift,
        ),
    };
  }

  static const _solid = {
    GlassLevel.regular: Color(0xFF17171A),
    GlassLevel.elevated: Color(0xFF1C1C20),
    GlassLevel.floating: Color(0xFF222227),
    GlassLevel.sheet: Color(0xFF242429),
  };

  static final _full = {
    GlassLevel.regular: const GlassSpec(
      fillTop: Color(0x0DFFFFFF), // 0.05
      fillBottom: Color(0x09FFFFFF), // 0.035
      blurSigma: 0,
      saturation: 1,
      border: SdColors.hairline,
      highlight: Color(0x00000000),
      shadows: [],
      radius: SdRadius.row,
    ),
    GlassLevel.elevated: GlassSpec(
      fillTop: const Color(0x17FFFFFF), // 0.09
      fillBottom: const Color(0x0DFFFFFF), // 0.05
      blurSigma: 0,
      saturation: 1,
      border: SdColors.hairline,
      highlight: const Color(0x24FFFFFF), // 0.14
      shadows: [BoxShadow(color: SdColors.shadow.withValues(alpha: 0.42), offset: const Offset(0, 14), blurRadius: 34, spreadRadius: -14)],
      radius: SdRadius.card,
      hoverLift: 2,
    ),
    GlassLevel.floating: GlassSpec(
      fillTop: const Color(0x21FFFFFF), // 0.13
      fillBottom: const Color(0x14FFFFFF), // 0.08
      blurSigma: 24,
      saturation: 1.7,
      border: SdColors.hairlineStrong,
      highlight: const Color(0x38FFFFFF), // 0.22
      shadows: [BoxShadow(color: SdColors.shadow.withValues(alpha: 0.5), offset: const Offset(0, 18), blurRadius: 48, spreadRadius: -16)],
      radius: SdRadius.sheet,
    ),
    GlassLevel.sheet: GlassSpec(
      fillTop: const Color(0x24FFFFFF), // 0.14
      fillBottom: const Color(0x17FFFFFF), // 0.09
      blurSigma: 34,
      saturation: 1.8,
      border: SdColors.hairlineStrong,
      highlight: const Color(0x3DFFFFFF), // 0.24
      shadows: [BoxShadow(color: SdColors.shadow.withValues(alpha: 0.6), offset: const Offset(0, 30), blurRadius: 80, spreadRadius: -20)],
      radius: SdRadius.sheet,
    ),
  };
}
