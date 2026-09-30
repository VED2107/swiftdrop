import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/picking.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../design/design.dart';
import '../screen_frame.dart';

/// One transfer, live. Everything on screen comes from the engine's snapshot (≤ 10/s):
/// who sends, who receives, how they're connected, how far, how fast, verified or not.
class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key, required this.transferId});
  final String transferId;

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  TransferPhase? _lastPhase;
  int? _restoredAt; // bytes when the link came back
  Timer? _restoredTimer;

  @override
  void dispose() {
    _restoredTimer?.cancel();
    super.dispose();
  }

  void _track(TransferSnapshot s) {
    if (_lastPhase == TransferPhase.reconnecting && s.phase == TransferPhase.running) {
      _restoredAt = s.bytesDone;
      _restoredTimer?.cancel();
      _restoredTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _restoredAt = null);
      });
    }
    _lastPhase = s.phase;
  }

  Future<void> _done() async {
    await ref.read(transferServiceProvider).dismiss(widget.transferId);
    if (mounted) context.canPop() ? context.pop() : context.go(Routes.home);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(transferProvider(widget.transferId));
    final ep = ref.watch(endpointProvider).value;
    if (s == null) return _Gone(transferId: widget.transferId, onDone: () => context.canPop() ? context.pop() : context.go(Routes.home));
    _track(s);
    final t = context.sdText;
    final svc = ref.read(transferServiceProvider);
    final sending = s.role == TransferRole.sending;
    final self = (name: ep?.name ?? 'This device', kind: Platform.isAndroid || Platform.isIOS ? DeviceKind.phone : DeviceKind.desktop);
    final other = (name: s.peerName, kind: s.peerKind);
    final live = s.phase == TransferPhase.running;

    if (s.phase == TransferPhase.complete) return _Complete(s: s, onDone: _done);

    final title = switch (s.phase) {
      TransferPhase.awaitingAcceptance => sending ? 'Waiting' : 'Starting',
      TransferPhase.reconnecting => 'Connection interrupted',
      TransferPhase.paused => 'Paused',
      TransferPhase.declined => 'Declined',
      TransferPhase.failed => 'Didn’t finish',
      TransferPhase.cancelled => 'Cancelled',
      _ => sending ? 'Sending' : 'Receiving',
    };
    final line = sending ? 'to ${s.peerName}' : 'from ${s.peerName}';
    final remaining = s.etaSeconds == null || !live ? null : formatRemaining(s.etaSeconds!);

    return ScreenFrame(
      title: title,
      subtitle: line,
      maxWidth: 720,
      children: [
        const SizedBox(height: SdSpace.s8),
        TransferVisual(
          progress: s.fraction,
          filesDone: s.filesDone,
          filesTotal: s.filesTotal,
          live: live,
          sender: sending ? self : other,
          receiver: sending ? other : self,
        ),
        if (s.path != null) Center(child: PathBadge(path: s.path)),
        const SizedBox(height: SdSpace.s8),
        // The readout: confirmed bytes first, then how fast and how long.
        Semantics(
          liveRegion: false,
          label: '${formatBytes(s.bytesDone)} of ${formatBytes(s.bytesTotal)}',
          excludeSemantics: true,
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: SdSpace.s3, children: [
            Text(formatBytes(s.bytesDone, digits: 2), style: t.numericHero),
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('of ${formatBytes(s.bytesTotal, digits: 2)}', style: t.numeric.copyWith(color: SdColors.text2))),
          ]),
        ),
        const SizedBox(height: SdSpace.s4),
        ProgressGlass(value: s.fraction, live: live, height: 10, semanticsLabel: title),
        const SizedBox(height: SdSpace.s4),
        _Stats(items: [
          ('${(s.fraction * 100).floor()}%', 'done'),
          (live && s.speed > 0 ? formatRate(s.speed) : '--', 'speed'),
          (remaining ?? '--', 'remaining'),
          ('${formatCount(s.filesDone)} / ${formatCount(s.filesTotal)}', 'files'),
        ]),
        const SizedBox(height: SdSpace.s8),
        ..._stateBlock(context, s, svc),
      ],
    );
  }

  List<Widget> _stateBlock(BuildContext context, TransferSnapshot s, TransferService svc) {
    final sending = s.role == TransferRole.sending;
    Widget cancel() => GlassButton(label: 'Cancel transfer', kind: GlassButtonKind.quiet, expand: true, onPressed: () => svc.cancel(s.transferId));
    switch (s.phase) {
      case TransferPhase.awaitingAcceptance:
        return [
          InlineBanner(
            title: sending ? 'Waiting for ${s.peerName} to accept' : 'Getting ready',
            message: sending ? 'Nothing is sent until they say yes on their device.' : null,
          ),
          const SizedBox(height: SdSpace.s3),
          cancel(),
        ];
      case TransferPhase.running:
        return [
          if (_restoredAt != null) ...[
            InlineBanner(
              tone: BannerTone.success,
              icon: SdIcons.verified,
              title: 'Connection restored',
              message: 'Resumed from ${formatBytes(_restoredAt!)}. Nothing was sent twice.',
            ),
            const SizedBox(height: SdSpace.s3),
          ],
          if (sending) SecondaryAction(label: 'Pause', icon: SdIcons.pause, expand: true, onPressed: () => svc.pause(s.transferId)),
          const SizedBox(height: SdSpace.s2),
          cancel(),
        ];
      case TransferPhase.reconnecting:
        return [
          InlineBanner(
            icon: SdIcons.local,
            title: 'Your transfer is safe',
            message: '${formatBytes(s.bytesDone)} already transferred and kept. Waiting for ${s.peerName} to be reachable again; it continues by itself.',
          ),
          const SizedBox(height: SdSpace.s3),
          cancel(),
        ];
      case TransferPhase.paused:
        return [
          InlineBanner(
            title: s.error == ErrorCode.diskFull ? 'The receiving device is out of space' : 'Paused',
            message: '${formatBytes(s.bytesDone)} already transferred. Resume continues from there.',
          ),
          const SizedBox(height: SdSpace.s3),
          PrimaryAction(label: 'Resume from ${formatBytes(s.bytesDone)}', icon: SdIcons.play, expand: true, onPressed: () => svc.resume(s.transferId)),
          const SizedBox(height: SdSpace.s2),
          cancel(),
        ];
      case TransferPhase.declined:
        return [
          InlineBanner(title: '${s.peerName} declined', message: 'Nothing was sent.'),
          const SizedBox(height: SdSpace.s3),
          SecondaryAction(label: 'Done', expand: true, onPressed: _done),
        ];
      case TransferPhase.cancelled:
        return [
          InlineBanner(title: 'Cancelled', message: sending ? 'Files that already arrived were removed on the other device.' : 'Partial files were removed.'),
          const SizedBox(height: SdSpace.s3),
          SecondaryAction(label: 'Done', expand: true, onPressed: _done),
        ];
      case TransferPhase.failed:
        return [
          InlineBanner(
            tone: BannerTone.warning,
            icon: SdIcons.failed,
            title: 'The transfer stopped',
            message: s.error == null ? 'Something went wrong.' : userMessages[s.error!],
          ),
          const SizedBox(height: SdSpace.s3),
          if (sending) ...[
            SecondaryAction(label: 'Try again', icon: SdIcons.retry, expand: true, onPressed: () => svc.resume(s.transferId)),
            const SizedBox(height: SdSpace.s2),
          ],
          GlassButton(label: 'Done', kind: GlassButtonKind.quiet, expand: true, onPressed: _done),
        ];
      case TransferPhase.preparing || TransferPhase.complete:
        return const [];
    }
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.items});
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    return LiquidGlass(
      level: GlassLevel.regular,
      padding: const EdgeInsets.symmetric(vertical: SdSpace.s4, horizontal: SdSpace.s2),
      child: Row(children: [
        for (final (value, label) in items)
          Expanded(
            child: Semantics(
              label: '$label $value',
              excludeSemantics: true,
              child: Column(children: [
                Text(value, style: t.numericMedium, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
                const SizedBox(height: 2),
                Text(label, style: t.caption),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Transfer complete: an earned moment, short and calm.
class _Complete extends ConsumerWidget {
  const _Complete({required this.s, required this.onDone});
  final TransferSnapshot s;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.sdText;
    final record = (ref.watch(historyProvider).value ?? const <TransferRecord>[]).where((r) => r.transferId == s.transferId).firstOrNull;
    final avg = record?.averageSpeed;
    final receiving = s.role == TransferRole.receiving;
    return ScreenFrame(
      title: '',
      maxWidth: 520,
      children: [
        const SizedBox(height: SdSpace.s6),
        const Center(child: CompletionMark()),
        Center(child: Semantics(header: true, child: Text('Transfer complete', style: t.display, textAlign: TextAlign.center))),
        const SizedBox(height: SdSpace.s2),
        Center(child: Text(receiving ? 'from ${s.peerName}' : 'to ${s.peerName}', style: t.title.copyWith(color: SdColors.text2, fontWeight: FontWeight.w500))),
        const SizedBox(height: SdSpace.s8),
        _Stats(items: [
          (formatCount(s.filesTotal), s.filesTotal == 1 ? 'file' : 'files'),
          (formatBytes(s.bytesTotal, digits: 2), 'total'),
          (avg != null && avg > 0 ? formatRate(avg) : '--', 'average'),
        ]),
        const SizedBox(height: SdSpace.s4),
        Center(
          child: s.verified
              ? const StatusPill(label: 'Verified: every file matches the original', icon: SdIcons.verified, tone: StatusTone.live)
              : const StatusPill(label: 'Complete', icon: SdIcons.check),
        ),
        const SizedBox(height: SdSpace.s8),
        PrimaryAction(label: 'Done', expand: true, onPressed: onDone),
        if (receiving && s.location != null && !(Platform.isAndroid || Platform.isIOS)) ...[
          const SizedBox(height: SdSpace.s2),
          GlassButton(label: 'Show in folder', icon: SdIcons.openFolder, kind: GlassButtonKind.quiet, expand: true, onPressed: () => revealFolder(s.location!)),
        ],
      ],
    );
  }
}

/// The transfer isn't live any more (dismissed, or the app restarted): show what history knows.
class _Gone extends ConsumerWidget {
  const _Gone({required this.transferId, required this.onDone});
  final String transferId;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = (ref.watch(historyProvider).value ?? const <TransferRecord>[]).where((r) => r.transferId == transferId).firstOrNull;
    return ScreenFrame(
      title: record == null ? 'Transfer' : '${plural(record.fileCount, 'file')} · ${formatBytes(record.totalBytes)}',
      maxWidth: 520,
      children: [
        const SizedBox(height: SdSpace.s6),
        InlineBanner(
          title: record == null ? 'This transfer isn’t active any more' : switch (record.outcome) {
            TransferOutcome.completed => record.verified ? 'Completed and verified' : 'Completed',
            TransferOutcome.failed => 'Didn’t finish',
            TransferOutcome.cancelled => 'Cancelled',
            TransferOutcome.declined => 'Declined',
          },
          message: record == null ? 'You’ll find it in Transfers once it finishes.' : '${record.role == TransferRole.sending ? 'To' : 'From'} ${record.peerName}',
        ),
        const SizedBox(height: SdSpace.s4),
        SecondaryAction(label: 'Done', expand: true, onPressed: onDone),
      ],
    );
  }
}
