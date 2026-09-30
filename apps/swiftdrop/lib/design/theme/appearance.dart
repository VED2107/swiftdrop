import 'package:flutter/widgets.dart';

import '../tokens/materials.dart';

/// User preference for motion (Settings > Appearance > Motion).
enum MotionPreference { system, reduced, full }

/// Resolved appearance for the design layer: user settings combined with the platform's
/// accessibility flags. Components read this, never the settings store, so the design
/// system stays independent of the app's state management.
@immutable
class SdAppearance {
  const SdAppearance({required this.glass, required this.reduceMotion, this.transferActive = false});

  static const fallback = SdAppearance(glass: GlassMode.full, reduceMotion: false);

  final GlassMode glass;
  final bool reduceMotion;

  /// A transfer is running somewhere: the environment carries a little more energy.
  final bool transferActive;

  /// Platform flags win over preferences: high contrast forces solid surfaces (iOS
  /// Reduce Transparency reaches us the same way once the platform layer reports it),
  /// and the OS reduce-motion switch can't be overridden to "full".
  static SdAppearance resolve(
    BuildContext context, {
    required GlassMode glass,
    required MotionPreference motion,
    bool transferActive = false,
  }) {
    final mq = MediaQuery.maybeOf(context);
    final highContrast = mq?.highContrast ?? false;
    final osReduce = mq?.disableAnimations ?? false;
    return SdAppearance(
      glass: highContrast ? GlassMode.off : glass,
      reduceMotion: osReduce || motion == MotionPreference.reduced,
      transferActive: transferActive,
    );
  }

  static SdAppearance of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SdAppearanceScope>()?.appearance ?? fallback;

  @override
  bool operator ==(Object other) =>
      other is SdAppearance &&
      other.glass == glass &&
      other.reduceMotion == reduceMotion &&
      other.transferActive == transferActive;

  @override
  int get hashCode => Object.hash(glass, reduceMotion, transferActive);
}

class SdAppearanceScope extends InheritedWidget {
  const SdAppearanceScope({super.key, required this.appearance, required super.child});
  final SdAppearance appearance;

  @override
  bool updateShouldNotify(SdAppearanceScope old) => old.appearance != appearance;
}
