import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:swiftdrop_core/testing.dart';

import '../../design/design.dart';

/// Debug-only catalogue of the design system: every glass level, control and state on the
/// real environment. Golden tests render the same components.
class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final pad = MediaQuery.paddingOf(context);
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: EdgeInsets.fromLTRB(SdSpace.s6, pad.top + SdSpace.s6, SdSpace.s6, pad.bottom + SdSpace.s12),
        children: [
          Row(children: [
            GlassButton(label: 'Back', kind: GlassButtonKind.quiet, onPressed: () => context.pop()),
            const Spacer(),
          ]),
          Text('Design gallery', style: t.display),
          const SectionHeader('Glass levels'),
          Wrap(spacing: SdSpace.s4, runSpacing: SdSpace.s4, children: [
            for (final level in [GlassLevel.surface, GlassLevel.card])
              SizedBox(
                width: 200,
                height: 120,
                child: LiquidGlass(
                  level: level,
                  padding: const EdgeInsets.all(SdSpace.s4),
                  child: Text('${level.name}\nno blur', style: t.caption.copyWith(color: SdColors.text)),
                ),
              ),
          ]),
          const SizedBox(height: SdSpace.s3),
          Text('Floating and sheet levels blur for real; see the navigation panel and "Open sheet".', style: t.caption),
          const SectionHeader('Actions'),
          Wrap(spacing: SdSpace.s3, runSpacing: SdSpace.s3, children: [
            PrimaryAction(label: 'Send 1.8 GB', onPressed: () {}),
            SecondaryAction(label: 'Receive', icon: SdIcons.receive, onPressed: () {}),
            GlassButton(label: 'Cancel', kind: GlassButtonKind.quiet, onPressed: () {}),
            const PrimaryAction(label: 'Disabled', onPressed: null),
            SecondaryAction(
              label: 'Open sheet',
              onPressed: () => showGlassSheet<void>(context, semanticLabel: 'Incoming transfer', builder: (ctx) => const _SampleSheet()),
            ),
          ]),
          const SectionHeader('Status'),
          const Wrap(spacing: SdSpace.s2, runSpacing: SdSpace.s2, children: [
            PathBadge(path: LinkPath(kind: PathKind.local, link: LinkKind.tcp)),
            PathBadge(path: LinkPath(kind: PathKind.p2p, link: LinkKind.webrtc)),
            StatusPill(label: 'Available'),
            StatusPill(label: 'Offline', icon: SdIcons.offline, tone: StatusTone.muted),
          ]),
          const SectionHeader('Devices'),
          Wrap(spacing: SdSpace.s4, runSpacing: SdSpace.s4, children: [
            for (final d in demoDevices) DeviceGlassCard(device: d, width: 188, onSend: () {}),
            DeviceGlassCard(device: demoDevices[1].copyWith(status: DeviceStatus.connecting), width: 188, onSend: () {}),
          ]),
          const SectionHeader('Numbers'),
          Text('1.24 GB', style: t.numericHero),
          Text('94.0 MB/s   1m 12s left   24 files', style: t.numeric),
        ],
      ),
    );
  }
}

class _SampleSheet extends StatelessWidget {
  const _SampleSheet();

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Incoming transfer', style: t.title),
      const SizedBox(height: SdSpace.s1),
      Text("Ved's iPhone", style: t.body.copyWith(color: SdColors.text2)),
      const SizedBox(height: SdSpace.s6),
      Text('24 files', style: t.numeric),
      Text('1.8 GB', style: t.numeric.copyWith(color: SdColors.text2)),
      const SizedBox(height: SdSpace.s6),
      PrimaryAction(label: 'Accept', expand: true, onPressed: () => Navigator.of(context).pop()),
      const SizedBox(height: SdSpace.s2),
      GlassButton(label: 'Decline', kind: GlassButtonKind.quiet, expand: true, onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}
