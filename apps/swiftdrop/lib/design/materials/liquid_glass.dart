import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../theme/appearance.dart';
import '../tokens/materials.dart';
import '../tokens/motion.dart';

/// The one glass implementation. Every translucent surface in the app is a [LiquidGlass]
/// at one of four [GlassLevel]s; nothing else sets blur, fill or edge light.
///
/// Layers, outside in: tinted shadow → continuous-corner clip → (backdrop blur +
/// saturation: floating and sheet levels only) → light-from-above fill (+ optional tint)
/// → child → hairline border, specular top edge and, on desktop, a sheen that follows the
/// pointer. Interactive surfaces respond physically: the rim brightens and the surface
/// lifts a couple of points on hover, and settles on press.
class LiquidGlass extends StatefulWidget {
  const LiquidGlass({
    super.key,
    required this.level,
    required this.child,
    this.radius,
    this.tint,
    this.tintStrength = 0.08,
    this.padding = EdgeInsets.zero,
    this.interactive = false,
  });

  final GlassLevel level;
  final Widget child;

  /// Token radius override (see `SdRadius`); defaults to the level's radius.
  final double? radius;

  /// Colour mixed into the fill, e.g. red for a connected device or a live transfer.
  final Color? tint;
  final double tintStrength;
  final EdgeInsetsGeometry padding;

  /// Hover lift, rim response and pointer sheen (the surface itself is the control).
  final bool interactive;

  @override
  State<LiquidGlass> createState() => _LiquidGlassState();
}

class _LiquidGlassState extends State<LiquidGlass> {
  bool _counted = false;
  bool _hover = false;
  final _pointer = ValueNotifier<Offset?>(null);

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
    _pointer.dispose();
    super.dispose();
  }

  /// A real blur counts against the budget only while it can be seen: offstage tabs and
  /// covered routes run with tickers disabled.
  void _syncBudget() {
    final blurs = SdMaterials.spec(widget.level, SdAppearance.of(context).glass).blurSigma > 0;
    final want = blurs && TickerMode.valuesOf(context).enabled;
    if (want == _counted) return;
    _counted = want;
    want ? GlassBudget.instance._acquire() : GlassBudget.instance._release();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = SdAppearance.of(context);
    final spec = SdMaterials.spec(widget.level, appearance.glass);
    final radius = Radius.circular(widget.radius ?? spec.radius);
    final shape = RoundedSuperellipseBorder(borderRadius: BorderRadius.all(radius));
    final tint = widget.tint;
    Color mix(Color c) => tint == null ? c : Color.alphaBlend(tint.withValues(alpha: widget.tintStrength), c);
    final lit = widget.interactive && _hover;

    Widget surface = CustomPaint(
      foregroundPainter: _EdgePainter(
        radius: radius,
        border: lit ? Color.lerp(spec.border, const Color(0x40FFFFFF), 0.6)! : spec.border,
        highlight: spec.highlight,
        pointer: widget.interactive && appearance.glass != GlassMode.off ? _pointer : null,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [mix(spec.fillTop), mix(spec.fillBottom)],
          ),
        ),
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );

    if (spec.blurSigma > 0) {
      final blur = ui.ImageFilter.blur(sigmaX: spec.blurSigma, sigmaY: spec.blurSigma, tileMode: TileMode.mirror);
      final filter = spec.saturation == 1 ? blur : ui.ImageFilter.compose(outer: blur, inner: _saturate(spec.saturation));
      // Grouped: sibling glass surfaces share one backdrop read (BackdropGroup in the app root).
      surface = BackdropFilter.grouped(filter: filter, child: surface);
    }

    Widget glass = RepaintBoundary(
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, shadows: spec.shadows),
        child: ClipRSuperellipse(borderRadius: BorderRadius.all(radius), child: surface),
      ),
    );

    if (!widget.interactive) return glass;
    final lift = lit && !appearance.reduceMotion ? -spec.hoverLift : 0.0;
    glass = TweenAnimationBuilder<double>(
      tween: Tween(end: lift),
      duration: SdMotion.small,
      curve: SdMotion.easeOut,
      builder: (context, v, child) => Transform.translate(offset: Offset(0, v), child: child),
      child: glass,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) {
        _pointer.value = null;
        setState(() => _hover = false);
      },
      onHover: (e) {
        if (e.kind == PointerDeviceKind.mouse) _pointer.value = e.localPosition;
      },
      child: glass,
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
  _EdgePainter({required this.radius, required this.border, required this.highlight, this.pointer}) : super(repaint: pointer);
  final Radius radius;
  final Color border;
  final Color highlight;
  final ValueListenable<Offset?>? pointer;

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
    if (highlight.a > 0) {
      // Light catching the top edge, fading out by mid-height.
      canvas.drawRSuperellipse(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = ui.Gradient.linear(
            rect.topCenter,
            Offset(rect.center.dx, rect.top + (size.height * 0.45).clamp(12.0, 64.0)),
            [highlight, highlight.withValues(alpha: 0)],
          ),
      );
    }
    final at = pointer?.value;
    if (at != null) {
      // Sheen: the rim nearest the pointer catches light, as if the pointer were a lamp.
      final reach = size.shortestSide * 0.9;
      canvas.drawRSuperellipse(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..shader = ui.Gradient.radial(at, reach, [const Color(0x59FFFFFF), const Color(0x00FFFFFF)]),
      );
      canvas.save();
      canvas.clipRSuperellipse(shape);
      canvas.drawCircle(
        at,
        reach,
        Paint()..shader = ui.Gradient.radial(at, reach, [const Color(0x0DFFFFFF), const Color(0x00FFFFFF)]),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.radius != radius || old.border != border || old.highlight != highlight || old.pointer != pointer;
}

/// Counts real backdrop blurs on screen. The design allows [SdMaterials.blurBudget]
/// (floating chrome + one sheet); a debug build reports an error when a screen exceeds
/// it, which also fails widget tests.
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
          'at most ${SdMaterials.blurBudget}. Use GlassLevel.elevated or .regular for anything '
          'that does not float over scrolling content.',
        ),
        library: 'swiftdrop design',
      ));
    }
  }

  void _release() => active.value = (active.value - 1).clamp(0, 1 << 20);
}
