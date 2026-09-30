import 'package:flutter/material.dart';

import '../design/design.dart';

/// Page layout shared by the sections: large title, gutters by window class, a readable
/// max width on big windows, and bottom padding that clears the phone's floating panel.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({super.key, required this.title, required this.children, this.actions = const []});

  final String title;

  /// Desktop/tablet: shown beside the title. Phones get their actions in the dock.
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final layout = SdLayout.of(context);
    final gutter = layout.isPhone ? SdSpace.gutterPhone : SdSpace.gutterWide;
    final pad = MediaQuery.paddingOf(context);
    return Material(
      type: MaterialType.transparency,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(gutter, pad.top + (layout.isPhone ? SdSpace.s4 : SdSpace.s8), gutter, pad.bottom + SdSpace.s8),
            sliver: SliverToBoxAdapter(
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                        Expanded(child: Semantics(header: true, child: Text(title, style: context.sdText.display))),
                        if (!layout.isPhone)
                          for (final a in actions) Padding(padding: const EdgeInsets.only(left: SdSpace.s3), child: a),
                      ]),
                      ...children,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
