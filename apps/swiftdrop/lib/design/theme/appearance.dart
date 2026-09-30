import 'package:flutter/widgets.dart';

import '../tokens/materials.dart';

/// User preference for motion (Settings > Appearance > Motion).
enum MotionPreference { system, reduced, full }

/// User preference for contrast (Settings > Appearance > High contrast).
enum ContrastPreference { system, high }

/// What the environment behind the glass expresses. It follows the product's state; it
/// never runs for decoration.
enum EnvironmentState {
  /// Calm: nothing going on.
  idle,

  /// Looking for devices / waiting for one to connect: a slow breath in the cool field.
  searching,

  /// A device is connected: a soft local glow.
  connected,

  /// Bytes are moving: a faint directional band, pace tied to measured throughput.
  transferring,
}

/// Resolved appearance for the design layer: user settings combined with the platform's
/// accessibility flags and the product state. Components read this, never the settings
/// store, so the design system stays independent of the app's state management.
@immutable
class SdAppearance {
  const SdAppearance({
    required this.glass,
    required this.reduceMotion,
    this.highContrast = false,
    this.environment = EnvironmentState.idle,
    this.energy = 0,
    this.completions = 0,
  });

  static const fallback = SdAppearance(glass: GlassMode.full, reduceMotion: false);

  final GlassMode glass;
  final bool reduceMotion;
  final bool highContrast;
  final EnvironmentState environment;

  /// 0..1: measured throughput relative to a fast LAN, drives the transfer band's pace.
  final double energy;

  /// Increments when a transfer completes: the environment plays one short bloom.
  final int completions;

  /// Platform flags win over preferences: high contrast forces solid surfaces (iOS
  /// Reduce Transparency reaches us the same way once the platform layer reports it),
  /// and the OS reduce-motion switch can't be overridden to "full".
  static SdAppearance resolve(
    BuildContext context, {
    required GlassMode glass,
    required MotionPreference motion,
    ContrastPreference contrast = ContrastPreference.system,
    EnvironmentState environment = EnvironmentState.idle,
    double energy = 0,
    int completions = 0,
  }) {
    final mq = MediaQuery.maybeOf(context);
    final highContrast = (mq?.highContrast ?? false) || contrast == ContrastPreference.high;
    final osReduce = mq?.disableAnimations ?? false;
    return SdAppearance(
      glass: highContrast ? GlassMode.off : glass,
      reduceMotion: osReduce || motion == MotionPreference.reduced,
      highContrast: highContrast,
      environment: environment,
      energy: energy.clamp(0, 1),
      completions: completions,
    );
  }

  static SdAppearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SdAppearanceScope>()?.appearance ?? fallback;

  @override
  bool operator ==(Object other) =>
      other is SdAppearance &&
      other.glass == glass &&
      other.reduceMotion == reduceMotion &&
      other.highContrast == highContrast &&
      other.environment == environment &&
      (other.energy - energy).abs() < 0.02 &&
      other.completions == completions;

  @override
  int get hashCode => Object.hash(glass, reduceMotion, highContrast, environment, (energy * 50).round(), completions);
}

class SdAppearanceScope extends InheritedWidget {
  const SdAppearanceScope({super.key, required this.appearance, required super.child});
  final SdAppearance appearance;

  @override
  bool updateShouldNotify(SdAppearanceScope old) => old.appearance != appearance;
}
