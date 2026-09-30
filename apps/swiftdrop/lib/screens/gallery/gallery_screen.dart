import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:swiftdrop_core/testing.dart';

import '../../design/design.dart';
import '../screen_frame.dart';

/// Debug-only catalogue of the design system on the real environment, including parts
/// not wired to real flows yet (the pairing confirmation code arrives with Phase 7).
class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final demo = TransferSnapshot(
      transferId: 'demo',
      role: TransferRole.sending,
      peerId: 'p',
      peerName: "Ved's iPhone",
      peerKind: DeviceKind.phone,
      phase: TransferPhase.running,
      bytesDone: 1240000000,
      bytesTotal: 1800000000,
      filesDone: 16,
      filesTotal: 24,
      speed: 94e6,
      etaSeconds: 42,
      startedAt: DateTime(2026),
      label: '24 files',
    );
    return ScreenFrame(
      title: 'Design gallery',
      maxWidth: 900,
      children: [
        const SectionHeader('Glass levels'),
        Wrap(spacing: SdSpace.s4, runSpacing: SdSpace.s4, children: [
          for (final level in [GlassLevel.regular, GlassLevel.elevated])
            SizedBox(
              width: 200,
              height: 110,
              child: LiquidGlass(
                level: level,
                interactive: level == GlassLevel.elevated,
                padding: const EdgeInsets.all(SdSpace.s4),
                child: Text('${level.name}\nno blur', style: t.caption.copyWith(color: SdColors.text)),
              ),
            ),
        ]),
        const SizedBox(height: SdSpace.s2),
        Text('Floating and sheet levels blur for real: the navigation, the send dock and "Open sheet".', style: t.caption),
        const SectionHeader('Actions'),
        Wrap(spacing: SdSpace.s3, runSpacing: SdSpace.s3, children: [
          PrimaryAction(label: 'Send 1.8 GB', onPressed: () {}),
          SecondaryAction(label: 'Receive', icon: SdIcons.receive, onPressed: () {}),
          GlassButton(label: 'Cancel', kind: GlassButtonKind.quiet, onPressed: () {}),
          const PrimaryAction(label: 'Disabled', onPressed: null),
          SecondaryAction(
            label: 'Open sheet',
            onPressed: () => showGlassSheet<void>(context, semanticLabel: 'Confirm code', builder: (ctx) => const _SasSheet()),
          ),
        ]),
        const SectionHeader('Status'),
        const Wrap(spacing: SdSpace.s2, runSpacing: SdSpace.s2, children: [
          PathBadge(path: LinkPath(kind: PathKind.local, link: LinkKind.tcp)),
          PathBadge(path: LinkPath(kind: PathKind.p2p, link: LinkKind.webrtc)),
          StatusPill(label: 'Ready'),
          StatusPill(label: 'Offline', icon: SdIcons.offline, tone: StatusTone.muted),
        ]),
        const SectionHeader('Devices'),
        Wrap(spacing: SdSpace.s4, runSpacing: SdSpace.s4, children: [
          for (final d in demoDevices) DeviceGlassCard(device: d, width: 196, onSend: () {}),
          DeviceGlassCard(device: demoDevices[1].copyWith(status: DeviceStatus.connecting), width: 196, onSend: () {}),
          DeviceGlassCard(device: demoDevices[0].copyWith(status: DeviceStatus.busy), width: 196, onSend: () {}),
        ]),
        const SectionHeader('Transfer'),
        TransferGlassCard(transfer: demo, onOpen: () {}),
        const SizedBox(height: SdSpace.s6),
        TransferVisual(
          progress: demo.fraction,
          filesDone: demo.filesDone,
          filesTotal: demo.filesTotal,
          live: true,
          sender: (name: 'This PC', kind: DeviceKind.desktop),
          receiver: (name: demo.peerName, kind: DeviceKind.phone),
        ),
        const SectionHeader('Completion'),
        const Center(child: CompletionMark()),
        const SectionHeader('Code'),
        const Center(child: QrCodeGlassContainer(data: 'swiftdrop://connect?a=192.168.1.20:47800&n=Gallery')),
        const SectionHeader('Numbers'),
        Text('1.24 GB', style: t.numericHero),
        Text('94.0 MB/s   1m 12s left   24 files', style: t.numeric),
      ],
    );
  }
}

class _SasSheet extends StatelessWidget {
  const _SasSheet();

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Confirm this code matches', style: t.title),
      const SizedBox(height: SdSpace.s1),
      Text('The same six digits appear on the other device.', style: t.caption),
      const SizedBox(height: SdSpace.s6),
      const Center(child: SasCode('482913')),
      const SizedBox(height: SdSpace.s6),
      PrimaryAction(label: 'Confirm', expand: true, onPressed: () => Navigator.of(context).pop()),
      const SizedBox(height: SdSpace.s2),
      GlassButton(label: 'They don’t match', kind: GlassButtonKind.quiet, expand: true, onPressed: () => Navigator.of(context).pop()),
    ]);
  }
}
