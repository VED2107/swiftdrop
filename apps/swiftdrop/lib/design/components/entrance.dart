import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';
import '../tokens/motion.dart';

/// Arrival for content that appears once per visit (a screen's sections, the home tiles):
/// fade up 12 pt, 320 ms ease-out, staggered 50 ms by [index]. It plays once on mount,
/// never on rebuild. Reduce Motion: a short opacity fade, no movement.
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final reduce = SdAppearance.of(context).reduceMotion;
    if (reduce) _c.duration = SdMotion.reduced;
    Future<void>.delayed(Duration(milliseconds: reduce ? 0 : 50 * widget.index.clamp(0, 8)), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = SdAppearance.of(context).reduceMotion;
    final curve = CurvedAnimation(parent: _c, curve: SdMotion.easeOut);
    return FadeTransition(
      opacity: curve,
      child: reduce
          ? widget.child
          : SlideTransition(position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(curve), child: widget.child),
    );
  }
}
