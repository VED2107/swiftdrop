import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/picking.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/design.dart';
import 'universal_qr.dart';
import '../screen_frame.dart';

/// Ready to receive: how the other device reaches this one.
class ReceiveScreen extends ConsumerWidget {
  const ReceiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transfers =
        ref.watch(transfersProvider).value ?? const <TransferSnapshot>[];
    final incoming = transfers
        .where((t) => t.role == TransferRole.receiving && !t.phase.isFinished)
        .toList();
    return ScreenFrame(
      title: 'Ready to receive',
      subtitle: 'Files come straight to this device.',
      maxWidth: 560,
      children: [
        const SizedBox(height: SdSpace.s6),
        for (final t in incoming) ...[
          TransferGlassCard(
            transfer: t,
            onOpen: () => context.push(Routes.transfer(t.transferId)),
          ),
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
/// screen and as the desktop side panel. Two audiences: another SwiftDrop app, or a phone
/// without the app (an iPhone), which scans a browser link instead.
class ReceiveCard extends ConsumerStatefulWidget {
  const ReceiveCard({super.key, this.compact = false});
  final bool compact;

  @override
  ConsumerState<ReceiveCard> createState() => _ReceiveCardState();
}

class _ReceiveCardState extends ConsumerState<ReceiveCard> {
  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (compact) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Ready to receive', style: t.section),
            ),
            const SizedBox(height: SdSpace.s4),
          ],
          UniversalQr(endpoint: ep, size: compact ? 180 : 232),
          const SizedBox(height: SdSpace.s3),
          Text(
            'Visible as ${ep.name}',
            style: t.caption,
            textAlign: TextAlign.center,
          ),
          if (dir != null) ...[
            const SizedBox(height: SdSpace.s4),
            const Divider(height: 1, color: SdColors.hairline),
            const SizedBox(height: SdSpace.s3),
            Row(
              children: [
                const Icon(SdIcons.folder, size: 18, color: SdColors.text2),
                const SizedBox(width: SdSpace.s2),
                Expanded(
                  child: Text(
                    dir,
                    style: t.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!(Platform.isAndroid || Platform.isIOS))
                  GlassButton(
                    label: 'Show',
                    kind: GlassButtonKind.quiet,
                    compact: true,
                    onPressed: () => revealFolder(dir),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
