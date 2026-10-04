import 'package:flutter/widgets.dart';

/// The SwiftDrop mark: a drop in flight with a swift's forked tail, on the red app-icon
/// tile. Same geometry as the Windows/Android icons and the web favicon (256-unit art).
class SwiftMark extends StatelessWidget {
  const SwiftMark({super.key, this.size = 28, this.tile = true});
  final double size;

  /// false draws the red mark alone (no tile), for places that already sit on red.
  final bool tile;

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: CustomPaint(painter: _SwiftPainter(tile)));
}

class _SwiftPainter extends CustomPainter {
  _SwiftPainter(this.tile);
  final bool tile;

  static Path _mark() => Path()
    ..moveTo(79.45, 204.94)
    ..lineTo(98.16, 150.71)
    ..lineTo(41.5, 159.72)
    ..lineTo(97.57, 75.35)
    ..arcToPoint(const Offset(172.27, 164.37), radius: const Radius.circular(62.32), largeArc: true)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 256;
    canvas.scale(k);
    if (!tile) {
      canvas.drawPath(_mark(), Paint()..color = const Color(0xFFD8322A));
      return;
    }
    final rect = Rect.fromLTWH(0, 0, 256, 256);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(64)),
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.36, -0.48),
          radius: 0.95,
          colors: [Color(0xFFEF4236), Color(0xFFA91F18)],
        ).createShader(rect),
    );
    canvas.translate(128, 128);
    canvas.scale(0.62);
    canvas.translate(-128, -124);
    canvas.drawPath(_mark(), Paint()..color = const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(_SwiftPainter old) => old.tile != tile;
}
