import 'package:flutter/painting.dart';

/// SwiftDrop native palette. Near-black environment, soft white type, one red accent
/// that only ever means "your file is moving / arrived intact". Change the accent here and
/// it changes everywhere; nothing outside `lib/design/` names a colour.
abstract final class SdColors {
  // Environment
  static const ground = Color(0xFF0E0E10);
  static const groundRaised = Color(0xFF141417);

  // Type (white at stepped opacity, never pure white)
  static const text = Color(0xF0FFFFFF); // 0.94
  static const text2 = Color(0xA3FFFFFF); // 0.64
  static const text3 = Color(0x70FFFFFF); // 0.44

  // Lines
  static const hairline = Color(0x14FFFFFF); // 0.08
  static const hairlineStrong = Color(0x24FFFFFF); // 0.14

  // Accent: the site's grease-pencil red.
  static const red = Color(0xFFD8322A);
  static const redPressed = Color(0xFFA8221A);

  /// Red for small text and glyphs on the dark ground (contrast ≥ 4.5:1 on [ground]).
  static const redOnDark = Color(0xFFFF8A80);
  static const redGlow = Color(0x3DD8322A); // 0.24

  /// Text on a red fill.
  static const onRed = Color(0xFFFFFFFF);

  /// Neutral light fields of the ambient environment.
  static const ambientCool = Color(0xFF3A4150);
  static const ambientWarm = Color(0xFF3B3530);

  /// Scrim behind sheets.
  static const scrim = Color(0x8C000000);

  /// Shadows are tinted toward the ground, never pure black.
  static const shadow = Color(0xFF020203);

  /// QR tile: the one place with near-pure white on near-black, because scanners need
  /// maximum contrast (the code is never tinted, blurred or placed on glass).
  static const qrPaper = Color(0xFFFAFAFA);
  static const qrInk = Color(0xFF0E0E10);

  /// Destructive / failure text and glyphs (with a word and an icon, never colour alone).
  static const warning = Color(0xFFFFB38A);
}
