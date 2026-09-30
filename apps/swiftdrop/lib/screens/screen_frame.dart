import 'package:flutter/material.dart';

import '../design/design.dart';

/// Page layout shared by the sections: title (and optional line under it), gutters by
/// window class, a readable max width, an optional side panel on wide windows, and bottom
/// padding that clears the phone's floating panel.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.actions = const [],
    this.panel,
    this.maxWidth = 1120,
  });

  final String title;
  final String? subtitle;

  /// Beside the title on tablet/desktop. Phones get their actions in the dock.
  final List<Widget> actions;
  final List<Widget> children;

  /// Desktop ≥ 1240 pt: a right-hand panel (live transfer, receive card).
  final Widget? panel;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final layout = SdLayout.of(context);
    final t = context.sdText;
    final gutter = layout.isPhone ? SdSpace.gutterPhone : SdSpace.gutterWide;
    final pad = MediaQuery.paddingOf(context);
    final header = Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text(title, style: t.display)),
          if (subtitle != null) ...[
            const SizedBox(height: SdSpace.s1),
            Text(subtitle!, style: t.title.copyWith(color: SdColors.text2, fontWeight: FontWeight.w500)),
          ],
        ]),
      ),
      if (!layout.isPhone)
        for (final a in actions) Padding(padding: const EdgeInsets.only(left: SdSpace.s3), child: a),
    ]);

    final content = ListView(
      padding: EdgeInsets.fromLTRB(gutter, pad.top + (layout.isPhone ? SdSpace.s4 : SdSpace.s8), gutter, pad.bottom + SdSpace.s8),
      children: [
        Align(
          // Sections sit beside the sidebar; focused flows (narrow) centre on wide windows.
          alignment: maxWidth < 1000 ? Alignment.topCenter : Alignment.topLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, ...children]),
          ),
        ),
      ],
    );

    return Material(
      type: MaterialType.transparency,
      child: panel != null && layout.sidebarExpanded
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: content),
              SizedBox(
                width: 340,
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(0, pad.top + SdSpace.s8, gutter, SdSpace.s8),
                  child: panel,
                ),
              ),
            ])
          : content,
    );
  }
}

/// Right-click / long-press menu, themed from tokens (solid floating surface: menus sit
/// above everything and must not add a third live blur).
Future<void> showGlassMenu(BuildContext context, Offset position, List<({String label, IconData icon, VoidCallback? onTap, bool danger})> items) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final choice = await showMenu<int>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      for (var i = 0; i < items.length; i++)
        PopupMenuItem<int>(
          value: i,
          enabled: items[i].onTap != null,
          child: Row(children: [
            Icon(items[i].icon, size: 18, color: items[i].danger ? SdColors.warning : SdColors.text2),
            const SizedBox(width: SdSpace.s3),
            Text(items[i].label, style: context.sdText.body.copyWith(color: items[i].danger ? SdColors.warning : SdColors.text)),
          ]),
        ),
    ],
  );
  if (choice != null) items[choice].onTap?.call();
}

/// A small sheet asking for a name. Returns the new name, or null when cancelled.
Future<String?> showRenameSheet(BuildContext context, {required String title, required String current}) {
  final controller = TextEditingController(text: current);
  return showGlassSheet<String>(
    context,
    semanticLabel: title,
    builder: (ctx) {
      void save() {
        final v = controller.text.trim();
        Navigator.of(ctx).pop(v.isEmpty ? null : v);
      }

      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: ctx.sdText.title),
        const SizedBox(height: SdSpace.s5),
        GlassTextField(label: 'Name', controller: controller, autofocus: true, onSubmitted: (_) => save()),
        const SizedBox(height: SdSpace.s6),
        PrimaryAction(label: 'Save', expand: true, onPressed: save),
        const SizedBox(height: SdSpace.s2),
        GlassButton(label: 'Cancel', kind: GlassButtonKind.quiet, expand: true, onPressed: () => Navigator.of(ctx).pop()),
      ]);
    },
  );
}

/// Asks before something that can't be undone. Returns true when confirmed.
Future<bool> confirmSheet(BuildContext context, {required String title, required String message, required String confirm}) async {
  final ok = await showGlassSheet<bool>(
    context,
    semanticLabel: title,
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: ctx.sdText.title),
      const SizedBox(height: SdSpace.s2),
      Text(message, style: ctx.sdText.body.copyWith(color: SdColors.text2)),
      const SizedBox(height: SdSpace.s6),
      SecondaryAction(label: confirm, expand: true, onPressed: () => Navigator.of(ctx).pop(true)),
      const SizedBox(height: SdSpace.s2),
      GlassButton(label: 'Cancel', kind: GlassButtonKind.quiet, expand: true, onPressed: () => Navigator.of(ctx).pop(false)),
    ]),
  );
  return ok ?? false;
}
