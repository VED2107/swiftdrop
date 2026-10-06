import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Touch feedback with a vocabulary, so a person can feel what happened without looking:
///
///  - [tap]      pressing a key: a light tick
///  - [select]   choosing a value, flipping a switch, changing tab: a crisp click
///  - [arrive]   something asks for you (an incoming transfer, a connection made): medium
///  - [success]  a transfer finished and verified: a confirming double beat
///  - [problem]  something didn't work: a firm double knock
///
/// Phones only (the system also honours its own "touch feedback" switch), and the person
/// can turn it off in Settings. On Android 11+ success and problem use the system's
/// CONFIRM / REJECT effects, which each phone tunes to its own motor.
abstract final class Haptics {
  static bool enabled = true;

  /// Set once from the platform layer when it exists (Android).
  static Future<bool> Function(String effect)? nativeEffect;

  static bool get _touch => defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;
  static bool get _on => enabled && _touch;

  static void tap() {
    if (_on) HapticFeedback.lightImpact();
  }

  static void select() {
    if (_on) HapticFeedback.selectionClick();
  }

  static void arrive() {
    if (_on) HapticFeedback.mediumImpact();
  }

  static Future<void> success() async {
    if (!_on) return;
    if (await _native('confirm')) return;
    HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    if (enabled) HapticFeedback.lightImpact();
  }

  static Future<void> problem() async {
    if (!_on) return;
    if (await _native('reject')) return;
    HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 110));
    if (enabled) HapticFeedback.heavyImpact();
  }

  static Future<bool> _native(String effect) async {
    final f = nativeEffect;
    if (f == null) return false;
    try {
      return await f(effect);
    } catch (_) {
      return false;
    }
  }
}
