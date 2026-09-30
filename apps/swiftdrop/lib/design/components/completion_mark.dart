import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/appearance.dart';
import '../tokens/colors.dart';

/// The completion moment: a red check draws itself (260 ms) inside a ring, with one soft
/// ripple (once). Earned, rare, short. Reduce Motion: the finished mark, no ripple.
class CompletionMark extends StatefulWidget {
  const CompletionMark({super.key, this.size = 96});
  final double size;

  @override
  State<CompletionMark> createState() => _CompletionMarkState();
}

class _CompletionMarkState extends State<CompletionMark> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (SdAppearance.of(context).reduceMotion) {
      _c.value = 1;
    } else if (_c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Complete',
      image: true,
      child: SizedBox.square(
        dimension: widget.size * 1.6,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _MarkPainter(_c.value, widget.size)),
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.t, this.size);
  final double t;
  final double size;

  @override
  void paint(Canvas canvas, Size box) {
    final c = box.center(Offset.zero);
    final r = size / 2;
    // Ripple: one ring expanding and fading (first ~70% of the timeline).
    final rp = (t / 0.7).clamp(0.0, 1.0);
    if (rp > 0 && rp < 1) {
      canvas.drawCircle(c, r * (1 + 0.55 * Curves.easeOut.transform(rp)), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = SdColors.red.withValues(alpha: 0.45 * (1 - rp)));
    }
    // Disc and ring.
    final appear = Curves.easeOut.transform((t / 0.35).clamp(0.0, 1.0));
    canvas.drawCircle(c, r * (0.92 + 0.08 * appear), Paint()..color = SdColors.red.withValues(alpha: 0.14 * appear));
    canvas.drawCircle(c, r * (0.92 + 0.08 * appear), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = SdColors.red.withValues(alpha: 0.6 * appear));
    // Check: drawn along its path between 25% and 55% of the timeline (~260 ms).
    final cp = Curves.easeOut.transform(((t - 0.25) / 0.3).clamp(0.0, 1.0));
    if (cp <= 0) return;
    final p1 = c + Offset(-r * 0.36, r * 0.02);
    final p2 = c + Offset(-r * 0.08, r * 0.3);
    final p3 = c + Offset(r * 0.4, -r * 0.28);
    final l1 = (p2 - p1).distance;
    final l2 = (p3 - p2).distance;
    final drawn = cp * (l1 + l2);
    final path = Path()..moveTo(p1.dx, p1.dy);
    if (drawn <= l1) {
      final q = Offset.lerp(p1, p2, drawn / l1)!;
      path.lineTo(q.dx, q.dy);
    } else {
      path.lineTo(p2.dx, p2.dy);
      final q = Offset.lerp(p2, p3, math.min(1, (drawn - l1) / l2))!;
      path.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.07
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = SdColors.redOnDark);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.t != t;
}
