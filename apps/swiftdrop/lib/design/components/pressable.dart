import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/appearance.dart';
import '../tokens/colors.dart';
import '../tokens/motion.dart';
import '../tokens/radius.dart';

/// The single source of press feedback. Anything tappable is a [Pressable]:
/// scale 0.97 on press (120 ms ease-out), light haptic on touch devices, hand cursor and
/// hover lift on pointer devices only, a visible focus ring for keyboards, Enter/Space
/// activation, and one semantics node.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onPressed,
    this.semanticLabel,
    this.focusRadius = SdRadius.card,
    this.haptic = true,
    this.autofocus = false,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final double focusRadius;
  final bool haptic;
  final bool autofocus;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;
  bool _hovered = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  void _activate() {
    if (!_enabled) return;
    if (widget.haptic && _isTouchPlatform) HapticFeedback.lightImpact();
    widget.onPressed!();
  }

  static bool get _isTouchPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final reduce = SdAppearance.of(context).reduceMotion;
    final scale = _pressed && !reduce ? SdMotion.pressScale : 1.0;
    final opacity = !_enabled ? 0.4 : (_pressed && reduce ? 0.7 : 1.0);

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        autofocus: widget.autofocus,
        mouseCursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTap: _enabled ? _activate : null,
          excludeFromSemantics: true,
          child: AnimatedScale(
            scale: scale,
            duration: SdMotion.press,
            curve: SdMotion.easeOut,
            child: AnimatedOpacity(
              opacity: opacity,
              duration: SdMotion.press,
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: ShapeDecoration(
                  color: _hovered && _enabled ? const Color(0x0AFFFFFF) : const Color(0x00000000),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: SdRadius.all(widget.focusRadius),
                    side: _focused
                        ? const BorderSide(color: SdColors.redOnDark, width: 2, strokeAlign: BorderSide.strokeAlignOutside)
                        : BorderSide.none,
                  ),
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
