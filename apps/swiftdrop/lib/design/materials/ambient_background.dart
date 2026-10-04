import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';
import '../tokens/colors.dart';
import '../tokens/motion.dart';

/// The environment behind every surface: near-black ground and very large, very soft
/// light fields that express the product's state. It never animates for decoration.
///
///  - idle: the fields drift over 40–70 s cycles by a few percent. Light, not motion.
///  - searching: the cool field breathes slowly (looking for devices).
///  - connected: a soft glow where the devices sit.
///  - transferring: a faint band of light travels left to right; its pace follows the
///    measured throughput ([SdAppearance.energy]) and is capped. No data, no motion.
///  - completion: one short red bloom from below, then back to calm.
///
/// Repaints at most 20×/s (60 during the bloom); Reduce Motion freezes it per state.
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key, required this.child});
  final Widget child;

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> with TickerProviderStateMixin {
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_onTick);
  late final _searching = AnimationController(vsync: this, duration: SdMotion.ambientShift);
  late final _connected = AnimationController(vsync: this, duration: SdMotion.ambientShift);
  late final _transfer = AnimationController(vsync: this, duration: SdMotion.ambientShift);
  late final _bloom = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  final _band = ValueNotifier<double>(0);
  double _energy = 0;
  Duration _last = Duration.zero;
  int _completions = -1;

  void _onTick(Duration elapsed) {
    final interval = _bloom.isAnimating ? 16 : 50;
    final dtMs = (elapsed - _last).inMilliseconds;
    if (dtMs < interval) return;
    _last = elapsed;
    _time.value = elapsed.inMicroseconds / 1e6;
    // The band advances with measured throughput: ~one pass per 14 s when barely moving,
    // ~one per 3.5 s at a saturated fast LAN; never faster.
    if (_transfer.value > 0) _band.value = (_band.value + dtMs / 1000 * (0.07 + 0.22 * _energy)) % 1.0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = SdAppearance.of(context);
    _energy = a.energy;
    void to(AnimationController c, bool on) {
      if (a.reduceMotion) {
        c.value = on ? 1 : 0;
      } else if (on) {
        c.animateTo(1, curve: SdMotion.easeOut);
      } else {
        c.animateBack(0, curve: SdMotion.easeOut);
      }
    }

    to(_searching, a.environment == EnvironmentState.searching);
    to(_connected, a.environment == EnvironmentState.connected || a.environment == EnvironmentState.transferring);
    to(_transfer, a.environment == EnvironmentState.transferring);
    if (_completions >= 0 && a.completions > _completions && !a.reduceMotion) _bloom.forward(from: 0);
    _completions = a.completions;
    if (a.reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    for (final c in [_searching, _connected, _transfer, _bloom]) {
      c.dispose();
    }
    _time.dispose();
    _band.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            isComplex: true,
            painter: _AmbientPainter(
              time: _time,
              band: _band,
              searching: _searching,
              connected: _connected,
              transfer: _transfer,
              bloom: _bloom,
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _AmbientPainter extends CustomPainter {
  _AmbientPainter({
    required this.time,
    required this.band,
    required this.searching,
    required this.connected,
    required this.transfer,
    required this.bloom,
  }) : super(repaint: Listenable.merge([time, band, searching, connected, transfer, bloom]));

  final ValueListenable<double> time;
  final ValueListenable<double> band;
  final Animation<double> searching;
  final Animation<double> connected;
  final Animation<double> transfer;
  final Animation<double> bloom;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final shortest = size.shortestSide;
    final longest = size.longestSide;
    final drift = shortest * 0.04;
    canvas.drawRect(Offset.zero & size, Paint()..color = SdColors.ground);

    void field(Offset center, double radius, Color color, double alpha) {
      if (alpha <= 0.001) return;
      canvas.drawCircle(
        center,
        radius,
        Paint()..shader = ui.Gradient.radial(center, radius, [color.withValues(alpha: alpha), color.withValues(alpha: 0)]),
      );
    }

    Offset wander(double a, double b, double phase) =>
        Offset(math.sin(2 * math.pi * t / a + phase) * drift, math.cos(2 * math.pi * t / b + phase) * drift);

    final breath = searching.value * (0.5 + 0.5 * math.sin(2 * math.pi * t / 4.5));
    field(Offset(size.width * 0.12, size.height * 0.06) + wander(41, 53, 0), longest * 0.62, SdColors.ambientCool, 0.34 + 0.12 * breath);
    field(Offset(size.width * 0.96, size.height * 0.8) + wander(59, 47, 1.7), longest * 0.55, SdColors.ambientWarm, 0.28);
    // Where devices sit: a soft glow once one is connected.
    // A soft red glow always sits high on the right: the board's warm light, never loud.
    field(Offset(size.width * 0.78, -size.height * 0.08) + wander(53, 67, 0.9), longest * 0.5, SdColors.red, 0.1 + 0.03 * breath);
    field(Offset(size.width * 0.5, size.height * 0.3) + wander(37, 61, 2.4), shortest * 0.7, const Color(0xFF4A4A56), 0.22 * connected.value);
    // The red field, low, behind the primary actions; stronger while bytes move.
    final e = transfer.value;
    field(Offset(size.width * 0.5, size.height * (1.02 - 0.06 * e)) + wander(67, 43, 3.1), shortest * (0.78 - 0.1 * e), SdColors.red, 0.15 + 0.1 * e);

    if (e > 0.01) {
      // Directional band: a wide diagonal wash of light crossing left to right.
      final x = -0.4 + 1.8 * band.value;
      final center = Offset(size.width * x, size.height * 0.45);
      final w = size.width * 0.5;
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.linear(
            center - Offset(w, w * 0.3),
            center + Offset(w, w * 0.3),
            [const Color(0x00FFFFFF), SdColors.red.withValues(alpha: 0.06 * e), const Color(0x00FFFFFF)],
            [0, 0.5, 1],
          ),
      );
    }

    final b = bloom.value;
    if (b > 0 && b < 1) {
      // One short confirmation bloom rising from below.
      final r = shortest * (0.3 + 0.9 * Curves.easeOut.transform(b));
      field(Offset(size.width * 0.5, size.height * 0.62), r, SdColors.red, 0.22 * (1 - b));
    }
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => false; // repaints come from the listenables
}
