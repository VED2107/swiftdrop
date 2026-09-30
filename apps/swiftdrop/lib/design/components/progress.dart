import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';
import '../tokens/colors.dart';

/// Eases a value that arrives in steps (engine snapshots, ≤ 10/s) into continuous motion
/// on the UI clock. It only ever moves toward the latest real value, never beyond it, so
/// nothing on screen runs ahead of the data.
class SmoothValue extends StatefulWidget {
  const SmoothValue({super.key, required this.value, required this.builder, this.response = const Duration(milliseconds: 180)});
  final double value;
  final Duration response;
  final Widget Function(BuildContext context, double value) builder;

  @override
  State<SmoothValue> createState() => _SmoothValueState();
}

class _SmoothValueState extends State<SmoothValue> with SingleTickerProviderStateMixin {
  late double _shown = widget.value;
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final target = widget.value;
    final k = 1 - math.exp(-dt / (widget.response.inMicroseconds / 1e6 / 3));
    final next = _shown + (target - _shown) * k;
    setState(() => _shown = (target - next).abs() < 1e-4 ? target : next);
    if (_shown == target) {
      _ticker.stop();
      _last = Duration.zero;
    }
  }

  bool _reduce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = SdAppearance.of(context).reduceMotion;
  }

  @override
  void didUpdateWidget(SmoothValue old) {
    super.didUpdateWidget(old);
    if (widget.value == _shown) return;
    if (_reduce || widget.value < _shown) {
      _shown = widget.value; // jumps back (resets) and reduce-motion are instant
      return;
    }
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _shown);
}

/// Linear progress as glass: a recessed track and a red fill drawn by a painter (no
/// layout animation), with a soft glow on the leading edge while [live].
class ProgressGlass extends StatelessWidget {
  const ProgressGlass({super.key, required this.value, this.live = true, this.height = 8, this.semanticsLabel});
  final double value;
  final bool live;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      value: '${(value.clamp(0, 1) * 100).round()} percent',
      child: SizedBox(
        height: height,
        child: SmoothValue(
          value: value.clamp(0.0, 1.0),
          builder: (context, v) => CustomPaint(painter: _BarPainter(v, live), size: Size.infinite),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.v, this.live);
  final double v;
  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, r);
    canvas.drawRRect(track, Paint()..color = const Color(0x14FFFFFF));
    canvas.drawRRect(track.deflate(0.5), Paint()
      ..style = PaintingStyle.stroke
      ..color = SdColors.hairline);
    if (v <= 0) return;
    final w = math.max(size.height, size.width * v);
    final fill = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, size.height), r);
    final color = live ? SdColors.red : SdColors.text3;
    canvas.drawRRect(
      fill,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(w, 0), [color.withValues(alpha: 0.75), color]),
    );
    if (live) {
      canvas.drawCircle(
        Offset(w - size.height / 2, size.height / 2),
        size.height * 1.8,
        Paint()
          ..shader = ui.Gradient.radial(Offset(w - size.height / 2, size.height / 2), size.height * 1.8,
              [SdColors.red.withValues(alpha: 0.35), SdColors.red.withValues(alpha: 0)]),
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.v != v || old.live != live;
}
