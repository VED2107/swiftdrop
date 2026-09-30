import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/connect_code.dart';
import '../../app/picking.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

/// Ready to receive: how the other device reaches this one.
class ReceiveScreen extends ConsumerWidget {
  const ReceiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers = ref.watch(transfersProvider).value ?? const <TransferSnapshot>[];
    final incoming = transfers.where((t) => t.role == TransferRole.receiving && !t.phase.isFinished).toList();
    return ScreenFrame(
      title: 'Ready to receive',
      subtitle: 'Files come straight to this device.',
      maxWidth: 560,
      children: [
        const SizedBox(height: SdSpace.s6),
        for (final t in incoming) ...[
          TransferGlassCard(transfer: t, onOpen: () => context.push(Routes.transfer(t.transferId))),
          const SizedBox(height: SdSpace.s4),
        ],
        const ReceiveCard(),
        if (Platform.isAndroid || Platform.isIOS) ...[
          const SizedBox(height: SdSpace.s4),
          const InlineBanner(
            title: 'Keep SwiftDrop open while files arrive',
            message: 'Phones pause apps in the background. If that happens, the transfer waits and picks up where it stopped.',
          ),
        ],
      ],
    );
  }
}

/// This device's address and code, and where received files go. Used on the Receive
/// screen and as the desktop side panel.
class ReceiveCard extends ConsumerWidget {
  const ReceiveCard({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.sdText;
    final ep = ref.watch(endpointProvider).value;
    final dir = ref.watch(downloadDirProvider);
    if (ep == null || ep.primary == null) {
      return const EmptyState(
        icon: SdIcons.offline,
        title: 'Not reachable yet',
        message: 'Connect this device to Wi-Fi or a hotspot. Its address appears here once it has one.',
      );
    }
    return LiquidGlass(
      level: GlassLevel.regular,
      padding: const EdgeInsets.all(SdSpace.s5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (compact) ...[
          Align(alignment: Alignment.centerLeft, child: Text('Ready to receive', style: t.section)),
          const SizedBox(height: SdSpace.s4),
        ],
        QrCodeGlassContainer(data: connectUri(ep), size: compact ? 180 : 232, semanticLabel: 'Connection code for ${ep.name}'),
        const SizedBox(height: SdSpace.s4),
        Text('Visible as ${ep.name}', style: t.bodyStrong, textAlign: TextAlign.center),
        const SizedBox(height: SdSpace.s1),
        Text('On the other device, choose Connect and enter', style: t.caption, textAlign: TextAlign.center),
        const SizedBox(height: SdSpace.s2),
        // The address never wraps mid-number: it scales down on narrow panels instead.
        FittedBox(fit: BoxFit.scaleDown, child: SelectableText(ep.primary!, style: t.numeric, maxLines: 1)),
        GlassButton(
          label: 'Copy address',
          icon: SdIcons.copy,
          kind: GlassButtonKind.quiet,
          compact: true,
          onPressed: () => Clipboard.setData(ClipboardData(text: ep.primary!)),
        ),
        if (dir != null) ...[
          const SizedBox(height: SdSpace.s4),
          const Divider(height: 1, color: SdColors.hairline),
          const SizedBox(height: SdSpace.s3),
          Row(children: [
            const Icon(SdIcons.folder, size: 18, color: SdColors.text2),
            const SizedBox(width: SdSpace.s2),
            Expanded(child: Text(dir, style: t.caption, maxLines: 2, overflow: TextOverflow.ellipsis)),
            if (!(Platform.isAndroid || Platform.isIOS))
              GlassButton(label: 'Show', kind: GlassButtonKind.quiet, compact: true, onPressed: () => revealFolder(dir)),
          ]),
        ],
      ]),
    );
  }
}
