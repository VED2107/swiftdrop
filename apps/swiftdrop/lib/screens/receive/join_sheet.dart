import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../design/design.dart';

/// A phone without the app (an iPhone's browser) asks to connect. Nothing is granted
/// until the person here approves; the sheet can't be swiped away unanswered.
class JoinSheet extends ConsumerStatefulWidget {
  const JoinSheet({super.key, required this.join});
  final BrowserJoin join;

  @override
  ConsumerState<JoinSheet> createState() => _JoinSheetState();
}

class _JoinSheetState extends ConsumerState<JoinSheet> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(settingsProvider).notifyIncoming) SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _answer(bool approve) async {
    if (_busy) return;
    setState(() => _busy = true);
    final nav = Navigator.of(context);
    try {
      await ref.read(engineProvider)?.resolveJoin(widget.join.id, approve);
    } catch (_) {
      // Expired or already answered elsewhere: nothing left to decide.
    }
    if (nav.mounted) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final j = widget.join;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const DeviceGlyph(kind: DeviceKind.phone, size: 52, live: true),
        const SizedBox(width: SdSpace.s4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(j.returning ? 'Wants to connect again' : 'Wants to connect', style: t.caption),
            Text(j.deviceName, style: t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
      const SizedBox(height: SdSpace.s4),
      Text(
        j.viaCode
            ? 'Someone typed this device\'s code in a browser. Allow it only if it\'s the phone in front of you.'
            : 'A phone scanned this device\'s code. Once allowed, it can send files here and download what you share with it.',
        style: t.body,
      ),
      const SizedBox(height: SdSpace.s6),
      PrimaryAction(label: 'Allow', icon: SdIcons.check, expand: true, onPressed: _busy ? null : () => _answer(true)),
      const SizedBox(height: SdSpace.s2),
      GlassButton(label: 'Don\'t allow', kind: GlassButtonKind.quiet, expand: true, onPressed: _busy ? null : () => _answer(false)),
    ]);
  }
}
