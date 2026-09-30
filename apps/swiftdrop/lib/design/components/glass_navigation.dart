import 'package:flutter/material.dart';

import '../materials/liquid_glass.dart';
import '../tokens/breakpoints.dart';
import '../tokens/colors.dart';
import '../tokens/materials.dart';
import '../tokens/radius.dart';
import '../tokens/spacing.dart';
import '../tokens/typography.dart';
import 'pressable.dart';

class NavDestination {
  const NavDestination({required this.label, required this.icon, required this.selectedIcon, this.shortcut});
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Shown in the desktop sidebar ("Ctrl 1").
  final String? shortcut;
}

/// Primary navigation, shaped by the window:
///  - phone: one floating glass panel at the bottom holding the action dock (when given)
///    above the tabs. One surface, one backdrop blur, however many controls it holds.
///  - tablet: a floating glass rail.
///  - desktop: a glass sidebar (icons only below 1240 pt).
/// Switching sections never animates: it's frequent, and keyboard-driven on desktop.
class GlassNavigation extends StatelessWidget {
  const GlassNavigation({
    super.key,
    required this.destinations,
    required this.selected,
    required this.onSelect,
    this.dock,
    this.header,
    this.footer,
  });

  final List<NavDestination> destinations;
  final int selected;
  final ValueChanged<int> onSelect;

  /// Phone only: the primary actions, sharing the tab bar's glass.
  final Widget? dock;

  /// Sidebar only.
  final Widget? header;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final layout = SdLayout.of(context);
    if (layout.isPhone) return _bottom(context);
    if (!layout.hasSidebar) return _rail(context, expanded: false);
    return _rail(context, expanded: layout.sidebarExpanded);
  }

  Widget _bottom(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(SdSpace.s3, 0, SdSpace.s3, bottom > 0 ? bottom : SdSpace.s3),
      child: LiquidGlass(
        level: GlassLevel.floating,
        padding: const EdgeInsets.all(SdSpace.s2),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (dock != null) Padding(padding: const EdgeInsets.fromLTRB(SdSpace.s1, SdSpace.s1, SdSpace.s1, SdSpace.s2), child: dock),
          Semantics(
            container: true,
            label: 'Sections',
            child: Row(children: [
              for (var i = 0; i < destinations.length; i++)
                Expanded(child: _Tab(d: destinations[i], selected: i == selected, onTap: () => onSelect(i))),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _rail(BuildContext context, {required bool expanded}) {
    return Padding(
      padding: const EdgeInsets.all(SdSpace.s3),
      child: LiquidGlass(
        level: GlassLevel.floating,
        padding: const EdgeInsets.symmetric(vertical: SdSpace.s4, horizontal: SdSpace.s2),
        child: SizedBox(
          width: expanded ? 216 : 64,
          child: Column(
            crossAxisAlignment: expanded ? CrossAxisAlignment.stretch : CrossAxisAlignment.center,
            children: [
              if (header != null && expanded) Padding(padding: const EdgeInsets.fromLTRB(SdSpace.s3, 0, SdSpace.s3, SdSpace.s6), child: header),
              for (var i = 0; i < destinations.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: SdSpace.s1),
                  child: _RailItem(d: destinations[i], selected: i == selected, expanded: expanded, onTap: () => onSelect(i)),
                ),
              const Spacer(),
              if (footer != null && expanded) Padding(padding: const EdgeInsets.symmetric(horizontal: SdSpace.s3), child: footer),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.d, required this.selected, required this.onTap});
  final NavDestination d;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? SdColors.text : SdColors.text3;
    return Semantics(
      selected: selected,
      child: Pressable(
        onPressed: onTap,
        semanticLabel: d.label,
        focusRadius: SdRadius.row,
        child: ExcludeSemantics(
          child: SizedBox(
            height: 56,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
              Icon(selected ? d.selectedIcon : d.icon, size: 22, color: color),
              const SizedBox(height: 3),
              Text(d.label, style: context.sdText.micro.copyWith(color: color)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.d, required this.selected, required this.expanded, required this.onTap});
  final NavDestination d;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final color = selected ? SdColors.text : SdColors.text2;
    final item = DecoratedBox(
      decoration: ShapeDecoration(
        color: selected ? const Color(0x17FFFFFF) : const Color(0x00000000),
        shape: RoundedSuperellipseBorder(borderRadius: SdRadius.all(SdRadius.row)),
      ),
      child: SizedBox(
        height: 44,
        width: expanded ? null : 48,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: expanded ? SdSpace.s3 : 0),
          child: Row(
            mainAxisAlignment: expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              Icon(selected ? d.selectedIcon : d.icon, size: 20, color: color),
              if (expanded) ...[
                const SizedBox(width: SdSpace.s3),
                Expanded(child: Text(d.label, style: t.label.copyWith(color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w500))),
                if (d.shortcut != null) Text(d.shortcut!, style: t.numericSmall.copyWith(color: SdColors.text3, fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
    );
    final button = Semantics(
      selected: selected,
      child: Pressable(onPressed: onTap, semanticLabel: d.label, focusRadius: SdRadius.row, child: ExcludeSemantics(child: item)),
    );
    return expanded ? button : Tooltip(message: d.label, child: button);
  }
}
