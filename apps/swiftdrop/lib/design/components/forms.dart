import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/sd_icons.dart';
import '../materials/liquid_glass.dart';
import '../theme/appearance.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/motion.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'pressable.dart';

/// Text input on elevated glass. Label above, help or error below (never placeholder as
/// label), themed caret and selection.
class GlassTextField extends StatelessWidget {
  const GlassTextField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.help,
    this.error,
    this.onSubmitted,
    this.keyboardType,
    this.autofocus = false,
    this.inputFormatters,
    this.monospaceDigits = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? help;
  final String? error;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final bool autofocus;
  final List<TextInputFormatter>? inputFormatters;
  final bool monospaceDigits;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final style = monospaceDigits ? t.body.copyWith(fontFeatures: t.numeric.fontFeatures) : t.body;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label, style: t.caption.copyWith(color: SdColors.text)),
      const SizedBox(height: SdSpace.s2),
      LiquidGlass(
        level: GlassLevel.elevated,
        radius: SdRadius.row,
        padding: const EdgeInsets.symmetric(horizontal: SdSpace.s4),
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          onSubmitted: onSubmitted,
          style: style,
          cursorColor: SdColors.red,
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: hint,
            hintStyle: style.copyWith(color: SdColors.text3),
            contentPadding: const EdgeInsets.symmetric(vertical: SdSpace.s4),
          ),
        ),
      ),
      if (error != null || help != null) ...[
        const SizedBox(height: SdSpace.s2),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (error != null) ...[const Icon(SdIcons.failed, size: 16, color: SdColors.warning), const SizedBox(width: SdSpace.s2)],
          Expanded(child: Text(error ?? help!, style: t.caption.copyWith(color: error != null ? SdColors.warning : SdColors.text2))),
        ]),
      ],
    ]);
  }
}

/// A native-feeling settings group: a title, rows on one quiet glass surface, an
/// optional footer explaining the group.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.children, this.footer});
  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Padding(
      padding: const EdgeInsets.only(top: SdSpace.s8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: SdSpace.s1, bottom: SdSpace.s2),
          child: Semantics(header: true, child: Text(title, style: t.section)),
        ),
        LiquidGlass(
          level: GlassLevel.regular,
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1, thickness: 1, indent: SdSpace.s4, color: SdColors.hairline),
              children[i],
            ],
          ]),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(SdSpace.s1, SdSpace.s2, SdSpace.s1, 0),
            child: Text(footer!, style: t.caption),
          ),
      ]),
    );
  }
}

/// One settings row: icon, title, optional detail, and a trailing control or value.
class SettingsRow extends StatelessWidget {
  const SettingsRow({super.key, required this.title, this.icon, this.detail, this.trailing, this.onTap, this.below});
  final String title;
  final IconData? icon;
  final String? detail;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// A full-width control under the title (e.g. a segmented choice).
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: SdSpace.s4, vertical: SdSpace.s3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: SdSpace.touch - SdSpace.s3),
          child: Row(children: [
            if (icon != null) ...[Icon(icon, size: 20, color: SdColors.text2), const SizedBox(width: SdSpace.s3)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(title, style: t.body),
                if (detail != null) Text(detail!, style: t.caption),
              ]),
            ),
            if (trailing != null) ...[const SizedBox(width: SdSpace.s3), trailing!],
            if (onTap != null && trailing == null) const Icon(SdIcons.chevron, size: 18, color: SdColors.text3),
          ]),
        ),
        if (below != null) ...[const SizedBox(height: SdSpace.s3), below!],
      ]),
    );
    if (onTap != null) row = Pressable(onPressed: onTap, semanticLabel: title, focusRadius: SdRadius.row, haptic: false, child: row);
    return row;
  }
}

/// On/off control: a pill that fills red when on. Instant under Reduce Motion.
class GlassSwitch extends StatelessWidget {
  const GlassSwitch({super.key, required this.value, required this.onChanged, required this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final reduce = SdAppearance.of(context).reduceMotion;
    final d = reduce ? Duration.zero : SdMotion.small;
    return Semantics(
      toggled: value,
      label: label,
      child: Pressable(
        onPressed: onChanged == null ? null : () => onChanged!(!value),
        semanticLabel: label,
        focusRadius: SdRadius.pill,
        haptic: true,
        child: ExcludeSemantics(
          child: AnimatedContainer(
            duration: d,
            curve: SdMotion.easeOut,
            width: 52,
            height: 32,
            padding: const EdgeInsets.all(3),
            decoration: ShapeDecoration(
              color: value ? SdColors.red : const Color(0x24FFFFFF),
              shape: RoundedSuperellipseBorder(borderRadius: SdRadius.all(SdRadius.pill), side: const BorderSide(color: SdColors.hairline)),
            ),
            child: AnimatedAlign(
              duration: d,
              curve: SdMotion.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(color: SdColors.text, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1))]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum BannerTone { calm, success, warning }

/// Inline message: icon + words, calm by default. Used for interruption ("your transfer is
/// safe"), restoration and failures, never as a toast that disappears before it's read.
class InlineBanner extends StatelessWidget {
  const InlineBanner({super.key, required this.title, this.message, this.tone = BannerTone.calm, this.icon, this.action});
  final String title;
  final String? message;
  final BannerTone tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final color = switch (tone) {
      BannerTone.calm => SdColors.text2,
      BannerTone.success => SdColors.redOnDark,
      BannerTone.warning => SdColors.warning,
    };
    return Semantics(
      liveRegion: true,
      child: LiquidGlass(
        level: GlassLevel.regular,
        padding: const EdgeInsets.all(SdSpace.s4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon ?? SdIcons.info, size: 20, color: color),
          const SizedBox(width: SdSpace.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.bodyStrong),
              if (message != null) ...[const SizedBox(height: 2), Text(message!, style: t.caption)],
            ]),
          ),
          if (action != null) ...[const SizedBox(width: SdSpace.s3), action!],
        ]),
      ),
    );
  }
}
