import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';
import '../tokens/colors.dart';
import '../tokens/motion.dart';

/// The living environment behind everything: near-black ground with three very large,
/// very soft light fields (cool top-left, warm bottom-right, red low behind the actions).
///
/// Idle, the fields drift over 40–70 s cycles by a few percent of the screen: light, not
/// motion. While a transfer runs the red field brightens and gathers (energy), without
/// moving any faster. Drift repaints at most 20×/s because nothing moves more than a
/// fraction of a pixel per frame; Reduce Motion freezes it entirely.
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key, required this.child});
  final Widget child;

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> with TickerProviderStateMixin {
  static const _frameInterval = Duration(milliseconds: 50);

  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_onTick);
  late final AnimationController _energy = AnimationController(vsync: this, duration: SdMotion.ambientShift);
  Duration _lastPaint = Duration.zero;

  void _onTick(Duration elapsed) {
    if (elapsed - _lastPaint < _frameInterval) return;
    _lastPaint = elapsed;
    _time.value = elapsed.inMicroseconds / 1e6;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = SdAppearance.of(context);
    if (a.reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      _energy.value = a.transferActive ? 1 : 0;
    } else {
      if (!_ticker.isActive) _ticker.start();
      a.transferActive ? _energy.animateTo(1, curve: SdMotion.easeOut) : _energy.animateBack(0, curve: SdMotion.easeOut);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _energy.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(painter: _AmbientPainter(time: _time, energy: _energy), isComplex: true),
        ),
        widget.child,
      ],
    );
  }
}

class _AmbientPainter extends CustomPainter {
  _AmbientPainter({required this.time, required this.energy}) : super(repaint: Listenable.merge([time, energy]));
  final ValueListenable<double> time;
  final Animation<double> energy;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final e = energy.value;
    final shortest = size.shortestSide;
    final drift = shortest * 0.04;
    canvas.drawRect(Offset.zero & size, Paint()..color = SdColors.ground);

    void field(Offset center, double radius, Color color, double alpha) {
      final paint = Paint()
        ..shader = ui.Gradient.radial(center, radius, [color.withValues(alpha: alpha), color.withValues(alpha: 0)], [0, 1]);
      canvas.drawCircle(center, radius, paint);
    }

    Offset wander(double periodA, double periodB, double phase) => Offset(
          math.sin(2 * math.pi * t / periodA + phase) * drift,
          math.cos(2 * math.pi * t / periodB + phase) * drift,
        );

    field(Offset(size.width * 0.12, size.height * 0.08) + wander(41, 53, 0), shortest * 0.95, SdColors.ambientCool, 0.34);
    field(Offset(size.width * 0.95, size.height * 0.78) + wander(59, 47, 1.7), shortest * 0.85, SdColors.ambientWarm, 0.30);
    // The red field: low and centred, under where the primary actions live.
    final redCenter = Offset(size.width * 0.5, size.height * (1.02 - 0.06 * e)) + wander(67, 43, 3.1);
    field(redCenter, shortest * (0.75 - 0.12 * e), SdColors.red, 0.16 + 0.12 * e);
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => false; // repaints come from the listenables
}
