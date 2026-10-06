import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../app/settings.dart';
import '../../app/router.dart';
import '../../design/design.dart';

/// Incoming transfer: a system-level request. Nothing is received until the person here
/// taps Accept; Decline is always visible. The sheet can't be swiped away unanswered.
class IncomingSheet extends ConsumerStatefulWidget {
  const IncomingSheet({super.key, required this.offer});
  final IncomingOffer offer;

  @override
  ConsumerState<IncomingSheet> createState() => _IncomingSheetState();
}

class _IncomingSheetState extends ConsumerState<IncomingSheet> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Haptics.arrive();
    if (ref.read(settingsProvider).notifyIncoming) SystemSound.play(SystemSoundType.alert);
  }

  Future<void> _answer(bool accept) async {
    if (_busy) return;
    setState(() => _busy = true);
    final svc = ref.read(transferServiceProvider);
    final nav = Navigator.of(context);
    final router = GoRouter.of(context);
    accept ? await svc.accept(widget.offer.transferId) : await svc.decline(widget.offer.transferId);
    nav.pop();
    if (accept) router.push(Routes.transfer(widget.offer.transferId));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final o = widget.offer;
    final more = o.fileCount - o.sampleNames.length;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        DeviceGlyph(kind: o.from.kind, size: 52, live: true),
        const SizedBox(width: SdSpace.s4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Incoming transfer', style: t.caption),
            Text(o.from.name, style: t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
      const SizedBox(height: SdSpace.s5),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(plural(o.fileCount, 'file'), style: t.numeric),
        const SizedBox(width: SdSpace.s3),
        Text(formatBytes(o.totalBytes), style: t.numeric.copyWith(color: SdColors.text2)),
      ]),
      const SizedBox(height: SdSpace.s3),
      LiquidGlass(
        level: GlassLevel.regular,
        padding: const EdgeInsets.symmetric(horizontal: SdSpace.s4, vertical: SdSpace.s3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final n in o.sampleNames)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(SdIcons.file('', n), size: 16, color: SdColors.text3),
                const SizedBox(width: SdSpace.s2),
                Expanded(child: Text(n, style: t.caption.copyWith(color: SdColors.text), maxLines: 1, overflow: TextOverflow.ellipsis)),
              ]),
            ),
          if (more > 0) Padding(padding: const EdgeInsets.only(top: 2), child: Text('and ${formatCount(more)} more', style: t.caption)),
        ]),
      ),
      if (Platform.isAndroid) ...[
        const SizedBox(height: SdSpace.s3),
        Row(children: [
          const Icon(SdIcons.folder, size: 16, color: SdColors.text3),
          const SizedBox(width: SdSpace.s2),
          Expanded(child: Text(_saveLine(o.sampleNames, ref.watch(settingsProvider)), style: t.caption)),
        ]),
      ],
      if (!o.fits) ...[
        const SizedBox(height: SdSpace.s3),
        InlineBanner(
          tone: BannerTone.warning,
          icon: SdIcons.failed,
          title: 'Not enough space',
          message: 'This needs ${formatBytes(o.totalBytes)}; ${formatBytes(o.freeBytes ?? 0)} is free.',
        ),
      ],
      const SizedBox(height: SdSpace.s6),
      PrimaryAction(label: 'Accept', icon: SdIcons.receive, expand: true, onPressed: _busy || !o.fits ? null : () => _answer(true)),
      const SizedBox(height: SdSpace.s2),
      GlassButton(label: 'Decline', kind: GlassButtonKind.quiet, expand: true, onPressed: _busy ? null : () => _answer(false)),
    ]);
  }
}

const _mediaExt = {
  'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic', 'heif', 'avif', 'bmp', 'dng', 'mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi', '3gp', 'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus',
};

/// "Photos and videos go to your Gallery, other files to Downloads/SwiftDrop": judged from
/// the names the sheet shows; the engine sorts every file by its own type when it lands.
String _saveLine(List<String> names, AppSettings prefs) {
  final where = saveSummary(prefs);
  var media = 0;
  for (final n in names) {
    if (_mediaExt.contains(n.split('.').last.toLowerCase())) media++;
  }
  final other = names.length - media;
  if (media > 0 && other == 0) return 'Saved to ${where.media == 'Gallery' ? 'your Gallery' : where.media}';
  if (media == 0) return 'Saved to ${where.other}';
  return 'Photos and videos go to ${where.media == 'Gallery' ? 'your Gallery' : where.media}, other files to ${where.other}';
}
