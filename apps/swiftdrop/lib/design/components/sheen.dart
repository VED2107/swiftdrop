import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/appearance.dart';

/// Light catching a surface: a soft diagonal sheen sweeps across [child] when a pointer
/// arrives (750 ms, ease-out), and, with [every], once on its own at that interval so the
/// eye finds the main action. Pointer devices only for hover; never under Reduce Motion.
class Sheen extends StatefulWidget {
  const Sheen({super.key, required this.child, required this.radius, this.every});
  final Widget child;
  final BorderRadius radius;
  final Duration? every;

  @override
  State<Sheen> createState() => _SheenState();
}

class _SheenState extends State<Sheen> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 750));
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer?.cancel();
    if (widget.every != null && !SdAppearance.of(context).reduceMotion) {
      _timer = Timer.periodic(widget.every!, (_) => _sweep());
    }
  }

  void _sweep() {
    if (!mounted || _c.isAnimating || SdAppearance.of(context).reduceMotion) return;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _sweep(),
      child: Stack(fit: StackFit.passthrough, children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRRect(
              borderRadius: widget.radius,
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, _) {
                  if (_c.value == 0 || _c.value == 1) return const SizedBox.shrink();
                  final t = Curves.easeOutCubic.transform(_c.value);
                  final x = -1.6 + 3.2 * t;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment(x - 0.6, -1),
                        end: Alignment(x + 0.6, 1),
                        colors: const [Color(0x00FFFFFF), Color(0x47FFFFFF), Color(0x14FFFFFF), Color(0x00FFFFFF)],
                        stops: const [0.0, 0.45, 0.55, 1.0],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
