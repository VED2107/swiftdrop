import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';
import '../tokens/motion.dart';

/// One-shot entrance for things that newly appear (a discovered device, a new row):
/// opacity 0 → 1 with scale 0.96 → 1, ease-out. Never from scale 0. Under Reduce Motion,
/// opacity only.
class Appear extends StatelessWidget {
  const Appear({super.key, required this.child, this.delay = Duration.zero});
  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final reduce = SdAppearance.of(context).reduceMotion;
    final total = (reduce ? SdMotion.reduced : SdMotion.small) + delay;
    final start = total.inMicroseconds == 0 ? 0.0 : delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1, curve: SdMotion.easeOut),
      child: child,
      // Screen readers see the element from its first frame, not after the fade.
      builder: (context, v, child) => Opacity(
        opacity: v,
        alwaysIncludeSemantics: true,
        child: reduce ? child : Transform.scale(scale: 0.96 + 0.04 * v, child: child),
      ),
    );
  }
}
