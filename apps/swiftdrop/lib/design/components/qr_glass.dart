import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import '../materials/liquid_glass.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';

/// A QR code inside glass, never under it: the code sits on an opaque white tile with a
/// quiet zone, full contrast and crisp modules, so any camera reads it at a glance. The
/// glass only frames it. Payload is connection information only, never file data.
class QrCodeGlassContainer extends StatelessWidget {
  const QrCodeGlassContainer({super.key, required this.data, this.size = 232, this.semanticLabel = 'Connection code'});
  final String data;
  final double size;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final code = QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium);
    final image = QrImage(code);
    return LiquidGlass(
      level: GlassLevel.elevated,
      padding: const EdgeInsets.all(SdSpace.s4),
      child: Semantics(
        label: semanticLabel,
        image: true,
        child: Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(SdSpace.s4),
          decoration: const ShapeDecoration(color: SdColors.qrPaper, shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(SdRadius.row)))),
          child: CustomPaint(painter: _QrPainter(image)),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    // Whole-pixel modules keep edges sharp on any display.
    final cell = (size.shortestSide / n).floorToDouble();
    final offset = Offset((size.width - cell * n) / 2, (size.height - cell * n) / 2);
    final paint = Paint()
      ..color = SdColors.qrInk
      ..isAntiAlias = false;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (image.isDark(y, x)) canvas.drawRect(Rect.fromLTWH(offset.dx + x * cell, offset.dy + y * cell, cell, cell), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}

/// A short confirmation code, grouped in threes ("482 913"), for comparing two screens.
class SasCode extends StatelessWidget {
  const SasCode(this.code, {super.key});
  final String code;

  @override
  Widget build(BuildContext context) {
    final grouped = code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
    return Semantics(
      label: 'Confirmation code ${code.split('').join(' ')}',
      excludeSemantics: true,
      child: Text(
        grouped,
        style: Theme.of(context).textTheme.displaySmall!.copyWith(
          fontSize: 44,
          letterSpacing: 4,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: SdColors.text,
        ),
      ),
    );
  }
}
