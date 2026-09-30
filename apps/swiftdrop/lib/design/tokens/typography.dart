import 'package:flutter/material.dart';

import 'colors.dart';

/// Type roles. No font family is named: every style inherits the platform's system font
/// from the theme's base typography (SF Pro on Apple, Roboto on Android, Segoe UI on
/// Windows, the desktop default on Linux). Numbers always use tabular figures so live
/// values don't jitter as digits change.
@immutable
class SdTextStyles extends ThemeExtension<SdTextStyles> {
  const SdTextStyles({
    required this.display,
    required this.title,
    required this.section,
    required this.body,
    required this.bodyStrong,
    required this.caption,
    required this.label,
    required this.numericHero,
    required this.numeric,
    required this.numericSmall,
  });

  /// Screen titles ("SwiftDrop", "Transfers").
  final TextStyle display;

  /// Sheet and card titles, device names in detail views.
  final TextStyle title;

  /// Section headings inside a screen ("Nearby", "Recent").
  final TextStyle section;
  final TextStyle body;
  final TextStyle bodyStrong;

  /// Secondary lines: platform, status, metadata.
  final TextStyle caption;

  /// Buttons and tabs.
  final TextStyle label;

  /// The transfer screen's big number ("1.24 GB").
  final TextStyle numericHero;

  /// Speeds, sizes, counts in cards and rows.
  final TextStyle numeric;
  final TextStyle numericSmall;

  static const _tabular = [FontFeature.tabularFigures()];

  /// [base] carries the platform font family; roles only set size, weight, tracking.
  factory SdTextStyles.from(TextStyle base) {
    TextStyle s(double size, double height, FontWeight w, {double tracking = 0, Color color = SdColors.text}) =>
        base.copyWith(
          fontSize: size,
          height: height / size,
          fontWeight: w,
          letterSpacing: tracking,
          color: color,
          decoration: TextDecoration.none,
        );
    return SdTextStyles(
      display: s(34, 40, FontWeight.w700, tracking: -0.6),
      title: s(22, 28, FontWeight.w600, tracking: -0.3),
      section: s(17, 22, FontWeight.w600, tracking: -0.2),
      body: s(16, 22, FontWeight.w400, color: SdColors.text),
      bodyStrong: s(16, 22, FontWeight.w600),
      caption: s(13, 18, FontWeight.w400, color: SdColors.text2),
      label: s(15, 20, FontWeight.w600, tracking: -0.1),
      numericHero: s(56, 56, FontWeight.w600, tracking: -1.2).copyWith(fontFeatures: _tabular),
      numeric: s(20, 24, FontWeight.w600, tracking: -0.3).copyWith(fontFeatures: _tabular),
      numericSmall: s(13, 18, FontWeight.w500, color: SdColors.text2).copyWith(fontFeatures: _tabular),
    );
  }

  @override
  SdTextStyles copyWith() => this;

  @override
  SdTextStyles lerp(SdTextStyles? other, double t) => t < 0.5 || other == null ? this : other;
}

extension SdTextContext on BuildContext {
  SdTextStyles get sdText => Theme.of(this).extension<SdTextStyles>()!;
}
