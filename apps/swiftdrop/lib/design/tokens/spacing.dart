import 'package:flutter/widgets.dart';

/// 4-pt spacing scale, same steps as the web app's `--s-*`.
abstract final class SdSpace {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;
  static const double s12 = 48;
  static const double s16 = 64;

  /// Side gutter by layout class.
  static const double gutterPhone = s5;
  static const double gutterWide = s8;

  /// Minimum touch target.
  static const double touch = 44;

  static const gap1 = SizedBox.square(dimension: s1);
  static const gap2 = SizedBox.square(dimension: s2);
  static const gap3 = SizedBox.square(dimension: s3);
  static const gap4 = SizedBox.square(dimension: s4);
  static const gap6 = SizedBox.square(dimension: s6);
  static const gap8 = SizedBox.square(dimension: s8);
}
