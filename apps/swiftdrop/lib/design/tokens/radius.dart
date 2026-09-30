import 'package:flutter/painting.dart';

/// One soft radius scale. No sharp corners anywhere in the app.
abstract final class SdRadius {
  static const double chip = 10;
  static const double row = 16;
  static const double card = 22;
  static const double sheet = 28;
  static const double pill = 999;

  static BorderRadius all(double r) => BorderRadius.all(Radius.circular(r));
}
