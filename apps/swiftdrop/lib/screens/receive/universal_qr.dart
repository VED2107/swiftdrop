import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/connect_code.dart';
import '../../design/design.dart';

/// The one code every guest scans: an iPhone's Camera opens the browser client, another
/// SwiftDrop app reads the app address from the same link. When this device sits on more
/// than one network (Ethernet to the router and Wi-Fi on a hotspot), the person picks the
/// one the other device is on; the code, address and fallback all follow that choice.
class UniversalQr extends StatefulWidget {
  const UniversalQr({super.key, required this.endpoint, this.size = 232});
  final LocalEndpoint endpoint;
  final double size;

  @override
  State<UniversalQr> createState() => _UniversalQrState();
}

class _UniversalQrState extends State<UniversalQr> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final ep = widget.endpoint;
    if (ep.addresses.isEmpty) {
      return const EmptyState(
        icon: SdIcons.offline,
        title: 'Not on a network yet',
        message: 'Join a Wi-Fi network or turn on a hotspot. Your code appears here as soon as this device has an address.',
      );
    }
    // A network that disappeared falls back to the best one still up.
    final picked = _picked;
    final address = picked != null && ep.addresses.contains(picked)
        ? picked
        : ep.addresses.first;
    final hostPort = '$address:${ep.port}';
    final web = ep.web;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ep.addresses.length > 1) ...[
          SegmentedGlass<String>(
            label: 'Network the other device is on',
            value: address,
            options: {for (final a in ep.addresses) a: ep.labels[a] ?? a},
            onChanged: (a) => setState(() => _picked = a),
          ),
          const SizedBox(height: SdSpace.s4),
        ],
        QrCodeGlassContainer(
          data: connectUri(ep, address: address),
          size: widget.size,
          semanticLabel: 'Connection code for ${ep.name}',
        ),
        const SizedBox(height: SdSpace.s4),
        Text(
          web == null
              ? 'Scan it with SwiftDrop, or enter the address'
              : 'iPhone: point the Camera at it. No app needed.',
          style: t.bodyStrong,
          textAlign: TextAlign.center,
        ),
        if (web != null) ...[
          const SizedBox(height: SdSpace.s1),
          Text(
            'SwiftDrop app: scan it, or Connect and enter the address.',
            style: t.caption,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: SdSpace.s2),
        // The address never wraps mid-number: it scales down on narrow panels instead.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: SelectableText(hostPort, style: t.numeric, maxLines: 1),
        ),
        GlassButton(
          label: 'Copy address',
          icon: SdIcons.copy,
          kind: GlassButtonKind.quiet,
          compact: true,
          onPressed: () => Clipboard.setData(ClipboardData(text: hostPort)),
        ),
        if (web != null) ...[
          const SizedBox(height: SdSpace.s2),
          Text(
            'No camera? In Safari open ${web.manual(address)} and type',
            style: t.caption,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SdSpace.s1),
          SelectableText(web.code, style: t.numeric.copyWith(letterSpacing: 4)),
        ],
      ],
    );
  }
}
