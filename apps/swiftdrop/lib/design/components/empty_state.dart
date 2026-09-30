import 'package:flutter/material.dart';

import '../materials/liquid_glass.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';

/// A composed empty state: what's missing, why, and the one thing to do about it.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return LiquidGlass(
      level: GlassLevel.regular,
      padding: const EdgeInsets.all(SdSpace.s6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: SdColors.text2),
          const SizedBox(height: SdSpace.s4),
          Text(title, style: t.section),
          const SizedBox(height: SdSpace.s1 + 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(message, style: t.body.copyWith(color: SdColors.text2)),
          ),
          if (action != null) ...[const SizedBox(height: SdSpace.s5), action!],
        ],
      ),
    );
  }
}

/// Section heading inside a screen. No eyebrow above it, no number before it.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: SdSpace.s8, bottom: SdSpace.s3),
      child: Row(children: [
        Expanded(child: Semantics(header: true, child: Text(title, style: context.sdText.section))),
        ?trailing,
      ]),
    );
  }
}
