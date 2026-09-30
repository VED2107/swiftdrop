import 'package:flutter/animation.dart';

/// Motion tokens. Curves match the web app's `--ease-*`; durations stay under 300 ms for
/// everyday UI, exits run faster than entries.
abstract final class SdMotion {
  /// Entering and responding: starts fast, settles softly.
  static const easeOut = Cubic(0.23, 1, 0.32, 1);

  /// Moving or morphing on screen.
  static const easeInOut = Cubic(0.77, 0, 0.175, 1);

  /// Sheets and drawers (iOS-like).
  static const drawer = Cubic(0.32, 0.72, 0, 1);

  static const press = Duration(milliseconds: 120);
  static const small = Duration(milliseconds: 180);
  static const page = Duration(milliseconds: 260);
  static const sheet = Duration(milliseconds: 320);

  /// Slow "waiting" breath (pairing): calm, clearly not progress.
  static const breath = Duration(milliseconds: 2200);

  /// Energy change of the environment when a transfer starts or stops.
  static const ambientShift = Duration(milliseconds: 600);

  /// Opacity-only crossfade used instead of transforms under Reduce Motion.
  static const reduced = Duration(milliseconds: 150);

  static Duration exit(Duration enter) => enter * 0.7;

  /// Press feedback scale for anything tappable.
  static const pressScale = 0.97;

  /// Everyday spring: no visible overshoot.
  static final gentle = SpringDescription.withDampingRatio(mass: 1, stiffness: 380, ratio: 0.9);

  /// Only for the completion check: a hint of settle.
  static final settle = SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.8);
}
