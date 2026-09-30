import 'package:flutter/material.dart';

import '../materials/liquid_glass.dart';
import '../theme/appearance.dart';
import '../tokens/breakpoints.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';

/// Sheet glass over a scrim. Phones: rises from the bottom edge (drawer curve, 320 ms in,
/// faster out). Wider windows: a centred panel that settles in from 0.96. Reduce Motion:
/// crossfade only. Escape / scrim tap dismiss unless [dismissible] is false (Accept/Decline
/// sheets must be answered).
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  String? semanticLabel,
}) {
  final appearance = SdAppearance.of(context);
  final phone = SdLayout.of(context).isPhone;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'Close',
    barrierColor: SdColors.scrim,
    transitionDuration: appearance.reduceMotion ? SdMotion.reduced : SdMotion.sheet,
    pageBuilder: (context, _, _) => SdAppearanceScope(
      appearance: appearance,
      child: _SheetFrame(phone: phone, semanticLabel: semanticLabel, child: Builder(builder: builder)),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: SdMotion.drawer, reverseCurve: SdMotion.easeOut);
      if (appearance.reduceMotion) return FadeTransition(opacity: animation, child: child);
      if (phone) {
        return SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curved),
          child: child,
        );
      }
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(curved), child: child),
      );
    },
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.phone, required this.child, this.semanticLabel});
  final bool phone;
  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final sheet = LiquidGlass(
      level: GlassLevel.sheet,
      padding: EdgeInsets.fromLTRB(SdSpace.s6, SdSpace.s6, SdSpace.s6, SdSpace.s6 + (phone ? bottom : 0)),
      child: Material(type: MaterialType.transparency, child: child),
    );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: phone ? Alignment.bottomCenter : Alignment.center,
          child: Padding(
            padding: phone ? const EdgeInsets.all(SdSpace.s2) : const EdgeInsets.all(SdSpace.s8),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: sheet),
          ),
        ),
      ),
    );
  }
}
