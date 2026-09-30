import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../tokens/colors.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'device_glass_card.dart';
import 'progress.dart';

/// The transfer, drawn as what it is: two devices and the direct link between them.
///
/// - The line fills red from the sender as bytes are confirmed by the receiver.
/// - File tokens travel the line. Their position is a function of **confirmed bytes**,
///   not time: they move exactly as fast as data arrives, freeze when it stops (paused,
///   reconnecting), and never animate on their own.
/// - Snapshots arrive ≤ 10/s; [SmoothValue] eases between them on the UI clock without
///   ever passing the latest real value.
class TransferVisual extends StatelessWidget {
  const TransferVisual({
    super.key,
    required this.progress,
    required this.filesDone,
    required this.filesTotal,
    required this.live,
    required this.sender,
    required this.receiver,
    this.height = 150,
  });

  /// Confirmed bytes / total, 0..1.
  final double progress;
  final int filesDone;
  final int filesTotal;

  /// Bytes are moving right now.
  final bool live;
  final ({String name, DeviceKind kind}) sender;
  final ({String name, DeviceKind kind}) receiver;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    Widget end(({String name, DeviceKind kind}) d, String role) => SizedBox(
          width: 96,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DeviceGlyph(kind: d.kind, size: 56, live: live),
            const SizedBox(height: SdSpace.s2),
            Text(d.name, style: t.caption.copyWith(color: SdColors.text), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
            Text(role, style: t.micro, textAlign: TextAlign.center),
          ]),
        );

    return Semantics(
      label: 'From ${sender.name} to ${receiver.name}, ${(progress * 100).round()} percent',
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          end(sender, 'Sender'),
          Expanded(
            child: RepaintBoundary(
              child: SmoothValue(
                value: progress.clamp(0.0, 1.0),
                response: const Duration(milliseconds: 240),
                builder: (context, p) => CustomPaint(
                  size: Size.infinite,
                  painter: _LinkPainter(progress: p, files: filesTotal, live: live),
                ),
              ),
            ),
          ),
          end(receiver, 'Receiver'),
        ]),
      ),
    );
  }
}

class _LinkPainter extends CustomPainter {
  _LinkPainter({required this.progress, required this.files, required this.live});
  final double progress;
  final int files;
  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2 - 18; // aligned with the glyph centres
    final a = Offset(4, y);
    final b = Offset(size.width - 4, y);
    final len = b.dx - a.dx;

    // Link: faint track, then the confirmed part in red.
    canvas.drawLine(a, b, Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = const Color(0x1FFFFFFF));
    final done = Offset(a.dx + len * progress, y);
    if (progress > 0) {
      canvas.drawLine(a, done, Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(a, done, [SdColors.red.withValues(alpha: 0.35), live ? SdColors.red : SdColors.text3]));
    }

    // Tokens: a handful of file chips spaced along the link. Phase advances with confirmed
    // progress (about eight passes over a whole transfer), so they move only with data.
    final count = math.max(1, math.min(5, files));
    final passes = 8.0;
    for (var i = 0; i < count; i++) {
      final ph = (progress * passes + i / count) % 1.0;
      final x = a.dx + len * ph;
      // Fade in near the sender, out near the receiver.
      final edge = math.min(ph, 1 - ph) * 6;
      final alpha = (edge.clamp(0.0, 1.0)) * (live ? 0.95 : 0.35);
      if (alpha <= 0.02) continue;
      final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: 14, height: 18), const Radius.circular(4));
      if (live) {
        canvas.drawRRect(r.inflate(4), Paint()
          ..color = SdColors.red.withValues(alpha: 0.18 * alpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      }
      canvas.drawRRect(r, Paint()..color = Color.lerp(SdColors.text3, SdColors.text, live ? 1 : 0)!.withValues(alpha: alpha));
      // Folded corner: reads as a file, not a dot.
      canvas.drawLine(Offset(r.right - 5, r.top), Offset(r.right, r.top + 5), Paint()
        ..color = SdColors.ground.withValues(alpha: alpha)
        ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_LinkPainter old) => old.progress != progress || old.live != live || old.files != files;
}
