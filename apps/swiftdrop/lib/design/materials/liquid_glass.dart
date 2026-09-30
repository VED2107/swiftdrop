import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';
import '../tokens/materials.dart';

/// The one glass implementation. Every translucent surface in the app is a [LiquidGlass]
/// at one of four [GlassLevel]s; nothing else sets blur, fill or edge light.
///
/// Layers, outside in: tinted shadow → continuous-corner clip → (backdrop blur +
/// saturation, floating/sheet levels only) → fill → child → hairline border and specular
/// top edge. The whole surface is a repaint boundary, so a live child (progress) never
/// forces the backdrop to be re-sampled for its own sake.
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.level,
    required this.child,
    this.radius,
    this.tint,
    this.tintStrength = 0.08,
    this.padding = EdgeInsets.zero,
  });

  final GlassLevel level;
  final Widget child;

  /// Token radius override (see `SdRadius`); defaults to the level's radius.
  final double? radius;

  /// Optional colour mixed into the fill, e.g. red for an active transfer.
  final Color? tint;
  final double tintStrength;
  final EdgeInsetsGeometry padding;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  bool _counted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBudget();
  }

  @override
  void didUpdateWidget(LiquidGlass old) {
    super.didUpdateWidget(old);
    _syncBudget();
  }

  @override
  void dispose() {
    if (_counted) GlassBudget.instance._release();
    super.dispose();
  }

  /// A real blur counts against the budget only while it can be seen: offstage tabs and
  /// covered routes run with tickers disabled.
  void _syncBudget() {
    final blurs = SdMaterials.spec(widget.level, SdAppearance.of(context).glass).blurSigma > 0;
    final visible = TickerMode.valuesOf(context).enabled;
    final want = blurs && visible;
    if (want == _counted) return;
    _counted = want;
    want ? GlassBudget.instance._acquire() : GlassBudget.instance._release();
  }

  @override
  Widget build(BuildContext context) {
    final spec = SdMaterials.spec(widget.level, SdAppearance.of(context).glass);
    final radius = Radius.circular(widget.radius ?? spec.radius);
    final shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(radius));
    final tint = widget.tint;
    final fill = tint == null ? spec.fill : Color.alphaBlend(tint.withValues(alpha: widget.tintStrength), spec.fill);

    Widget surface = CustomPaint(
      foregroundPainter: _EdgePainter(radius: radius, border: spec.border, highlight: spec.highlight),
      child: ColoredBox(color: fill, child: Padding(padding: widget.padding, child: widget.child)),
    );

    if (spec.blurSigma > 0) {
      final blur = ui.ImageFilter.blur(sigmaX: spec.blurSigma, sigmaY: spec.blurSigma, tileMode: TileMode.mirror);
      final filter = spec.saturation == 1 ? blur : ui.ImageFilter.compose(outer: blur, inner: _saturate(spec.saturation));
      // Grouped: sibling glass surfaces share one backdrop read (see BackdropGroup in the app root).
      surface = BackdropFilter.grouped(filter: filter, child: surface);
    }

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, shadows: spec.shadows),
        child: ClipRSuperellipse(borderRadius: BorderRadius.all(radius), child: surface),
      ),
    );
  }
}

/// Saturation matrix (luminance-preserving), so colour behind the glass reads through.
ui.ColorFilter _saturate(double s) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final i = 1 - s;
  return ui.ColorFilter.matrix([
    r * i + s, g * i, b * i, 0, 0, //
    r * i, g * i + s, b * i, 0, 0,
    r * i, g * i, b * i + s, 0, 0,
    0, 0, 0, 1, 0,
  ]);
}

class _EdgePainter extends CustomPainter {
  _EdgePainter({required this.radius, required this.border, required this.highlight});
  final Radius radius;
  final Color border;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = ui.RSuperellipse.fromRectAndRadius(rect.deflate(0.5), radius);
    canvas.drawRSuperellipse(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = border,
    );
    if (highlight.a == 0) return;
    // Light catching the top edge, fading out by mid-height.
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = ui.Gradient.linear(
        rect.topCenter,
        Offset(rect.center.dx, rect.top + (size.height * 0.45).clamp(12.0, 64.0)),
        [highlight, highlight.withValues(alpha: 0)],
      );
    canvas.drawRSuperellipse(shape, edge);
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.radius != radius || old.border != border || old.highlight != highlight;
}

/// Counts real backdrop blurs on screen. The design allows [SdMaterials.blurBudget]
/// (floating chrome + one sheet); a debug build reports an error when a screen exceeds it,
/// which also fails widget tests.
class GlassBudget {
  GlassBudget._();
  static final instance = GlassBudget._();

  final ValueNotifier<int> active = ValueNotifier(0);

  void _acquire() {
    active.value++;
    if (kDebugMode && active.value > SdMaterials.blurBudget) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: FlutterError(
          'Liquid Glass budget exceeded: ${active.value} real backdrop blurs visible, '
          'at most ${SdMaterials.blurBudget}. Use GlassLevel.card or .surface for anything '
          'that does not float over scrolling content.',
        ),
        library: 'swiftdrop design',
      ));
    }
  }

  void _release() => active.value = (active.value - 1).clamp(0, 1 << 20);
}
