import 'dart:math';
import 'dart:typed_data';

import 'base64url.dart';

final _rng = Random.secure();

Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// URL-safe random id; 12 bytes → 16 characters (matches `/^[A-Za-z0-9_-]{6,64}$/`).
String randomId([int chars = 16]) => bytesToBase64Url(randomBytes((chars * 3 + 3) ~/ 4)).substring(0, chars);
