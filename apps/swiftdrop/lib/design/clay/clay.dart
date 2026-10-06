import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../haptics.dart';
import '../theme/appearance.dart';
import '../tokens/colors.dart';
import '../tokens/motion.dart';
import '../tokens/typography.dart';

/// "Clay console": SwiftDrop as a small molded instrument. Matte surfaces that are raised
/// (lit from above, soft shadow below) or recessed (wells for readouts and the rail),
/// puffy keys that squish when pressed and spring back, files as clay pebbles that roll
/// along a carved groove. No glass, no blur.
abstract final class Clay {
  static const body = Color(0xFF1C181C);
  static const bodyHi = Color(0xFF262126);
  static const well = Color(0xFF0F0D10);
  static const key = Color(0xFF2A2429);
  static const keyHi = Color(0xFF352E34);
  static const skirt = Color(0xFF110E11);
  static const redHi = Color(0xFFF04A3E);
  static const redLo = Color(0xFFB3241C);
  static const redSkirt = Color(0xFF7A140F);
  static const green = Color(0xFF6FDC9C);

  /// Raised: a top highlight and a soft drop below.
  static List<BoxShadow> raised([double lift = 1]) => [
        BoxShadow(color: const Color(0x99000000), offset: Offset(0, 10 * lift), blurRadius: 24 * lift, spreadRadius: -6),
        BoxShadow(color: const Color(0x14FFFFFF), offset: Offset(0, -1 * lift), blurRadius: 0),
      ];
}

/// A raised molded panel.
class ClaySurface extends StatelessWidget {
  const ClaySurface({super.key, required this.child, this.radius = 28, this.padding = const EdgeInsets.all(20), this.color});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Clay.body;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(c, Colors.white, 0.04)!, c]),
        boxShadow: Clay.raised(),
      ),
      child: child,
    );
  }
}

/// A recessed well (readouts, the rail groove): darker, lit edge at the bottom.
class ClayWell extends StatelessWidget {
  const ClayWell({super.key, required this.child, this.radius = 18, this.padding = const EdgeInsets.all(14)});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: Clay.well,
          border: const Border(bottom: BorderSide(color: Color(0x1AFFFFFF))),
          boxShadow: const [BoxShadow(color: Color(0xCC000000), offset: Offset(0, 3), blurRadius: 6, spreadRadius: -2)],
        ),
        child: child,
      );
}

/// A puffy key with real travel: it squishes 3 pt into its skirt when pressed (90 ms) and
/// springs back with a little overshoot. Red for the one action that moves things.
class ClayKey extends StatefulWidget {
  const ClayKey({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.red = false,
    this.expand = false,
    this.height = 52,
    this.semanticLabel,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool red;
  final bool expand;
  final double height;
  final String? semanticLabel;

  @override
  State<ClayKey> createState() => _ClayKeyState();
}

class _ClayKeyState extends State<ClayKey> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 90), reverseDuration: const Duration(milliseconds: 260));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() {
    if (widget.onPressed == null) return;
    _c.forward();
  }

  void _up() => _c.reverse();

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final top = widget.red ? Clay.redHi : Clay.keyHi;
    final bottom = widget.red ? Clay.redLo : Clay.key;
    final skirt = widget.red ? Clay.redSkirt : Clay.skirt;
    final fg = widget.red ? Colors.white : SdColors.text;
    const travel = 4.0;
    final t = context.sdText;
    final face = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[Icon(widget.icon, size: 20, color: fg), const SizedBox(width: 8)],
        Flexible(child: Text(widget.label, style: t.label.copyWith(color: fg, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
      ],
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel ?? widget.label,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            onTapDown: (_) => _down(),
            onTapUp: (_) => _up(),
            onTapCancel: _up,
            onTap: enabled
                ? () {
                    Haptics.tap();
                    widget.onPressed!();
                  }
                : null,
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, child) {
                final p = Curves.easeOut.transform(_c.value);
                final h = widget.height;
                final r = BorderRadius.circular(h * 0.32);
                // The face sizes the key; the skirt (its molded thickness) sits behind it.
                return Stack(children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: travel,
                    bottom: 0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: skirt,
                        borderRadius: r,
                        boxShadow: [BoxShadow(color: const Color(0x88000000), offset: Offset(0, 8 - 5 * p), blurRadius: 18 - 8 * p, spreadRadius: -6)],
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(top: travel * p, bottom: travel * (1 - p)),
                    child: Transform.scale(
                      scaleX: 1 + 0.015 * p,
                      scaleY: 1 - 0.03 * p,
                      child: Container(
                        height: h,
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        decoration: BoxDecoration(
                          borderRadius: r,
                          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]),
                          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: widget.red ? 0.28 : 0.1))),
                        ),
                        child: child,
                      ),
                    ),
                  ),
                ]);
              },
              child: Center(child: face),
            ),
          ),
        ),
      ),
    );
  }
}

/// The big round red Send key. Squishes like every key, and breathes slowly while idle so
/// it reads as "start here".
class ClaySendKey extends StatefulWidget {
  const ClaySendKey({super.key, required this.onPressed, this.size = 104, this.icon, this.label = 'Send'});
  final VoidCallback? onPressed;
  final double size;
  final IconData? icon;
  final String label;

  @override
  State<ClaySendKey> createState() => _ClaySendKeyState();
}

class _ClaySendKeyState extends State<ClaySendKey> with TickerProviderStateMixin {
  late final _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 90), reverseDuration: const Duration(milliseconds: 320));
  late final _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (SdAppearance.of(context).reduceMotion) {
      _breath.stop();
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _press.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final enabled = widget.onPressed != null;
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTapDown: (_) => enabled ? _press.forward() : null,
          onTapUp: (_) => _press.reverse(),
          onTapCancel: () => _press.reverse(),
          onTap: enabled
              ? () {
                  Haptics.arrive();
                  widget.onPressed!();
                }
              : null,
          child: AnimatedBuilder(
            animation: Listenable.merge([_press, _breath]),
            builder: (_, _) {
              final p = Curves.easeOut.transform(_press.value);
              final b = Curves.easeInOut.transform(_breath.value);
              final travel = s * 0.06;
              return SizedBox(
                width: s,
                height: s + travel,
                child: Stack(clipBehavior: Clip.none, children: [
                  // soft red halo on the body, breathing
                  Positioned(
                    left: -s * 0.18,
                    right: -s * 0.18,
                    top: -s * 0.1,
                    bottom: -s * 0.25,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(colors: [SdColors.red.withValues(alpha: 0.18 + 0.1 * b), SdColors.red.withValues(alpha: 0)]),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: s,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Clay.redSkirt,
                        boxShadow: [BoxShadow(color: const Color(0xAA000000), offset: Offset(0, 14 - 8 * p), blurRadius: 26 - 10 * p, spreadRadius: -8)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: travel * p,
                    height: s,
                    child: Transform.scale(
                      scaleX: 1 + 0.02 * p,
                      scaleY: 1 - 0.04 * p,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const RadialGradient(center: Alignment(-0.3, -0.45), radius: 0.9, colors: [Color(0xFFFF6A5C), Clay.redHi, Clay.redLo]),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1),
                        ),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(widget.icon ?? Icons.arrow_upward_rounded, color: Colors.white, size: s * 0.3),
                          Text(widget.label.toUpperCase(), style: context.sdText.micro.copyWith(color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
                        ]),
                      ),
                    ),
                  ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The transfer rail: a carved groove between two endpoints. Idle it is empty; linked it
/// glows faintly; moving, clay pebbles roll along it at a pace tied to the live speed and
/// the groove fills red behind them; done, it settles to one green line.
class TransferRail extends StatefulWidget {
  const TransferRail({super.key, required this.progress, required this.speed, required this.state, this.objects = 4, this.height = 44, this.burst = 0});

  /// 0..1 of bytes confirmed.
  final double progress;

  /// Bytes per second; drives how fast the pebbles roll.
  final double speed;
  final RailState state;
  final int objects;
  final double height;

  /// Bump to fire the parked pebbles down the rail once (the Send key does this).
  final int burst;

  @override
  State<TransferRail> createState() => _TransferRailState();
}

enum RailState { idle, linked, moving, done }

class _TransferRailState extends State<TransferRail> with SingleTickerProviderStateMixin {
  late final _t = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  double _phase = 0;
  double _clock = 0;
  double? _burstAt;
  Duration _last = Duration.zero;

  @override
  void didUpdateWidget(TransferRail old) {
    super.didUpdateWidget(old);
    if (widget.burst != old.burst) _burstAt = _clock;
  }

  @override
  void initState() {
    super.initState();
    _t.addListener(_advance);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce Motion paints a still rail: no frames are scheduled for it at all.
    if (SdAppearance.of(context).reduceMotion) {
      _t.stop();
    } else if (!_t.isAnimating) {
      _t.repeat();
    }
  }

  void _advance() {
    final now = _t.lastElapsedDuration ?? Duration.zero;
    final dt = ((now - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = now;
    _clock += dt;
    if (_burstAt != null && _clock - _burstAt! > 1.4) _burstAt = null;
    if (widget.state != RailState.moving) return;
    // ~0.15 rail-lengths/s at 10 MB/s, up to ~0.6 at 100 MB/s+: faster data, faster roll.
    final mbps = widget.speed / 1e6;
    final pace = 0.12 + 0.48 * (math.log(1 + mbps) / math.log(101)).clamp(0.0, 1.0);
    _phase = (_phase + dt * pace) % 1;
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = SdAppearance.of(context).reduceMotion;
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _t,
        builder: (_, _) => CustomPaint(
          size: Size.infinite,
          painter: _RailPainter(
            progress: widget.progress.clamp(0, 1),
            phase: reduce ? 0 : _phase,
            state: widget.state,
            objects: widget.objects.clamp(1, 6),
            showObjects: !reduce,
            clock: reduce ? 0 : _clock,
            burst: reduce || _burstAt == null ? null : ((_clock - _burstAt!) / 1.4).clamp(0.0, 1.0),
          ),
        ),
      ),
    );
  }
}

class _RailPainter extends CustomPainter {
  _RailPainter({required this.progress, required this.phase, required this.state, required this.objects, required this.showObjects, this.clock = 0, this.burst});
  final double progress;
  final double phase;
  final RailState state;
  final int objects;
  final bool showObjects;
  final double clock;

  /// 0..1 while a Send burst plays: the parked pebbles race to the far end, then reappear.
  final double? burst;

  static const _pebbles = [
    [Color(0xFFF6A26B), Color(0xFFC4485A)],
    [Color(0xFF8FD3F4), Color(0xFF4A7FB8)],
    [Color(0xFFFFD27A), Color(0xFFE9764F)],
    [Color(0xFFB6E3A8), Color(0xFF4E9A7A)],
    [Color(0xFFF7C6D9), Color(0xFFB56A9C)],
    [Color(0xFFE2D4FF), Color(0xFF7C6AB8)],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const groove = 12.0;
    final r = RRect.fromLTRBR(0, cy - groove / 2, size.width, cy + groove / 2, const Radius.circular(groove / 2));
    // carved groove: dark channel, lit lower lip
    canvas.drawRRect(r, Paint()..color = Clay.well);
    canvas.drawRRect(r.shift(const Offset(0, 1)), Paint()
      ..color = const Color(0x14FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
    // tick marks under the groove: the instrument's scale
    final tick = Paint()..color = const Color(0x26FFFFFF);
    for (var i = 0; i <= 20; i++) {
      final x = size.width * i / 20;
      canvas.drawRect(Rect.fromLTWH(x - 0.5, cy + groove / 2 + 6, 1, i % 5 == 0 ? 7 : 4), tick);
    }
    if (state != RailState.moving && showObjects) {
      // Parked pebbles waiting at the start of the rail, bobbing like they want to go.
      // A Send burst throws them down the groove; they land and new ones roll back in.
      for (var i = 0; i < 3; i++) {
        final colors = _pebbles[i];
        var x = 22.0 + i * 24;
        var y = cy - 2 - (math.sin(clock * 2.4 + i * 1.3) * 2.2).abs();
        var alpha = 1.0;
        final b = burst;
        if (b != null) {
          final local = ((b - i * 0.08) / 0.62).clamp(0.0, 1.0);
          final eased = Curves.easeInCubic.transform(local);
          x = x + (size.width - 30 - x) * eased;
          y = cy - math.sin(local * math.pi) * 18;
          if (b > 0.7) {
            // landed; fade back in at the start
            final back = ((b - 0.7) / 0.3).clamp(0.0, 1.0);
            x = 22.0 + i * 24;
            y = cy - 2;
            alpha = back;
          }
        }
        _pebble(canvas, Offset(x, y), 11, colors, alpha);
      }
    }
    if (state == RailState.idle) return;

    final fillColor = state == RailState.done ? Clay.green : SdColors.red;
    final fillW = state == RailState.linked ? size.width : size.width * (state == RailState.done ? 1 : progress);
    final fill = RRect.fromLTRBR(0, cy - groove / 2 + 3, math.max(groove, fillW), cy + groove / 2 - 3, const Radius.circular(groove / 2));
    canvas.drawRRect(
      fill,
      Paint()
        ..color = fillColor.withValues(alpha: state == RailState.linked ? 0.25 : 1)
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3),
    );
    if (state != RailState.moving || !showObjects) return;

    // pebbles: evenly spaced, rolling left to right, squashing a touch as they roll
    for (var i = 0; i < objects; i++) {
      final u = (phase + i / objects) % 1;
      final x = 14 + (size.width - 28) * u;
      final edge = math.min(u, 1 - u);
      final appear = (edge / 0.08).clamp(0.0, 1.0);
      final rad = 13.0 * (0.6 + 0.4 * appear);
      final bounce = math.sin(u * math.pi * 6).abs() * 3;
      final c = Offset(x, cy - bounce);
      final colors = _pebbles[i % _pebbles.length];
      _pebble(canvas, c, rad, colors, appear);
    }
  }

  void _pebble(Canvas canvas, Offset c, double rad, List<Color> colors, double alpha) {
    if (alpha <= 0) return;
    canvas.drawCircle(c.translate(0, 4), rad * 0.9, Paint()
      ..color = Color.fromRGBO(0, 0, 0, 0.4 * alpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(
      c,
      rad,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.5),
          colors: [Color.lerp(colors[0], Colors.white, 0.25)!.withValues(alpha: alpha), colors[0].withValues(alpha: alpha), colors[1].withValues(alpha: alpha)],
        ).createShader(Rect.fromCircle(center: c, radius: rad)),
    );
    canvas.drawCircle(c, rad, Paint()
      ..color = Colors.white.withValues(alpha: 0.85 * alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_RailPainter old) => true;
}

class ClayLamp extends StatelessWidget {
  const ClayLamp({super.key, required this.lit});
  final bool lit;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: SdMotion.small,
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: lit ? Clay.redHi : const Color(0xFF3A3337),
          boxShadow: lit ? const [BoxShadow(color: Color(0x99EF4236), blurRadius: 8)] : null,
        ),
      );
}

/// A destination key: a small clay key with the device's lamp; the chosen one sits pressed.
class ClayChoiceKey extends StatelessWidget {
  const ClayChoiceKey({super.key, required this.label, required this.icon, required this.selected, required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: SdMotion.small,
            curve: Curves.easeOut,
            height: 44,
            margin: EdgeInsets.only(top: selected ? 3 : 0, bottom: selected ? 0 : 3),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: selected ? Clay.well : Clay.key,
              border: Border(top: BorderSide(color: Colors.white.withValues(alpha: selected ? 0.02 : 0.1))),
              boxShadow: selected
                  ? const [BoxShadow(color: Color(0xCC000000), offset: Offset(0, 2), blurRadius: 4, spreadRadius: -1)]
                  : const [BoxShadow(color: Clay.skirt, offset: Offset(0, 3)), BoxShadow(color: Color(0x66000000), offset: Offset(0, 8), blurRadius: 14, spreadRadius: -6)],
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ClayLamp(lit: selected),
              const SizedBox(width: 8),
              Icon(icon, size: 16, color: SdColors.text2),
              const SizedBox(width: 6),
              // Narrow segments (170 wide on a small phone) ellipsize instead of overflowing.
              Flexible(
                child: Text(
                  label,
                  style: t.label.copyWith(color: selected ? SdColors.text : SdColors.text2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}


/// A device as a physical object: a molded clay puck with its glyph pressed in. The
/// destination puck bounces when the Send burst lands on it.
class ClayPuck extends StatefulWidget {
  const ClayPuck({super.key, required this.icon, required this.lit, required this.size, this.empty = false, this.landing = 0, this.emptyIcon});
  final IconData icon;
  final IconData? emptyIcon;
  final bool lit;
  final bool empty;
  final double size;
  final int landing;

  @override
  State<ClayPuck> createState() => _ClayPuckState();
}

class _ClayPuckState extends State<ClayPuck> with SingleTickerProviderStateMixin {
  late final _bounce = AnimationController(vsync: this, duration: SdMotion.sheet * 2.2);

  @override
  void didUpdateWidget(ClayPuck old) {
    super.didUpdateWidget(old);
    if (widget.landing != old.landing && !SdAppearance.of(context).reduceMotion) {
      Future<void>.delayed(SdMotion.sheet * 2.7, () {
        if (mounted) _bounce.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final icon = widget.icon;
    return AnimatedBuilder(
      animation: _bounce,
      builder: (_, child) {
        final v = _bounce.value;
        final squash = v == 0 ? 0.0 : math.sin(v * math.pi * 3) * (1 - v) * 0.12;
        return Transform.scale(scaleX: 1 + squash, scaleY: 1 - squash, child: child);
      },
      child: Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: widget.empty
              ? null
              : const RadialGradient(center: Alignment(-0.35, -0.45), radius: 0.95, colors: [Color(0xFF3B3439), Color(0xFF241F24)]),
          color: widget.empty ? Clay.well : null,
          border: Border.all(color: widget.lit ? Clay.redHi.withValues(alpha: 0.55) : const Color(0x14FFFFFF), width: widget.lit ? 2 : 1),
          boxShadow: widget.empty
              ? const [BoxShadow(color: Color(0xCC000000), offset: Offset(0, 2), blurRadius: 6, spreadRadius: -2)]
              : [
                  const BoxShadow(color: Clay.skirt, offset: Offset(0, 4)),
                  const BoxShadow(color: Color(0x88000000), offset: Offset(0, 12), blurRadius: 22, spreadRadius: -8),
                  if (widget.lit) BoxShadow(color: Clay.redHi.withValues(alpha: 0.25), blurRadius: 24),
                ],
        ),
        child: Icon(widget.empty ? (widget.emptyIcon ?? icon) : icon, size: s * 0.38, color: widget.empty ? SdColors.text3 : SdColors.text),
      ),
    );
  }
}

/// Where the destination puck sits: a new destination drops in with a springy scale.
class ClayPuckSlot extends StatelessWidget {
  const ClayPuckSlot({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: SdMotion.sheet * 1.6,
        switchInCurve: Curves.elasticOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => ScaleTransition(scale: Tween(begin: 0.4, end: 1.0).animate(anim), child: FadeTransition(opacity: anim, child: child)),
        child: KeyedSubtree(key: ValueKey(id), child: child),
      );
}
