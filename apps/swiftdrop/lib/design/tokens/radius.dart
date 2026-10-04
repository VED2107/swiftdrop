import 'package:flutter/painting.dart';

/// One soft radius scale. No sharp corners anywhere in the app.
abstract final class SdRadius {
  static const double chip = 12;
  static const double row = 18;
  static const double card = 26;
  static const double sheet = 32;
  static const double pill = 999;

  static BorderRadius all(double r) => BorderRadius.all(Radius.circular(r));
}
