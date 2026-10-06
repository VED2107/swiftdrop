import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/app.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/shell.dart';
import '../../design/clay/clay.dart';
import '../../design/design.dart';
import '../receive/receive_screen.dart';
import '../settings/update_ui.dart';

/// Home is one instrument: this device on the left, the destination on the right, and the
/// transfer rail between them. Choose a destination with its key, press the red Send key,
/// and the files roll across. Recent transfers sit in a recessed log underneath.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String? _dest;
  int _burst = 0;

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider).value ?? const <Device>[];
    final history = ref.watch(historyProvider).value ?? const <TransferRecord>[];
    final transfers = ref.watch(transfersProvider).value ?? const <TransferSnapshot>[];
    final ep = ref.watch(endpointProvider).value;
    final active = transfers.where((t) => !t.phase.isFinished).firstOrNull;
    final reachable = devices.where((d) => d.status != DeviceStatus.offline).toList();
    final dest = reachable.where((d) => d.id == _dest).firstOrNull ?? reachable.firstOrNull;
    final engineError = EngineStatus.of(context);
    final layout = SdLayout.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 1240;
    final gutter = layout.isPhone ? SdSpace.gutterPhone : SdSpace.gutterWide;
    final pad = MediaQuery.paddingOf(context);

    final console = Entrance(
      child: _Console(
        selfName: ep?.name ?? 'This device',
        selfAddress: ep?.primary,
        dest: dest,
        others: reachable,
        active: active,
        phone: layout.isPhone,
        onPick: (d) => setState(() => _dest = d.id),
        burst: _burst,
        onSend: () {
          setState(() => _burst++);
          startSend(context, ref, deviceId: dest?.id);
        },
        onOpenTransfer: active == null ? null : () => context.push(Routes.transfer(active.transferId)),
      ),
    );

    final main = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const SwiftMark(size: 34),
        const SizedBox(width: SdSpace.s3),
        Expanded(child: Text('SwiftDrop', style: layout.isPhone ? context.sdText.title : context.sdText.display, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ClayKey(label: 'Receive', icon: SdIcons.receiveDown, height: SdSpace.touch, onPressed: () => context.push(Routes.receive)),
        if (!layout.isPhone) ...[
          const SizedBox(width: SdSpace.s2),
          ClayKey(label: 'Connect', icon: SdIcons.connect, height: SdSpace.touch, onPressed: () => context.push(Routes.pair)),
        ],
      ]),
      if (engineError != null) ...[
        const SizedBox(height: SdSpace.s5),
        const InlineBanner(
          tone: BannerTone.warning,
          icon: SdIcons.failed,
          title: 'Transfers aren’t available right now',
          message: 'SwiftDrop couldn’t start its local connection. Restart the app; if it keeps happening, check that no other program blocks it.',
        ),
      ],
      const UpdateBanner(),
      const SizedBox(height: SdSpace.s6),
      console,
      const SizedBox(height: SdSpace.s8),
      Entrance(index: 1, child: _Log(records: history.take(6).toList(), onAll: () => context.go(Routes.transfers))),
    ]);

    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, pad.top + (layout.isPhone ? SdSpace.s4 : SdSpace.s8), gutter, pad.bottom + SdSpace.s8),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1360),
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: main),
                    const SizedBox(width: SdSpace.s6),
                    const SizedBox(width: 340, child: ReceiveCard(compact: true)),
                  ])
                : main,
          ),
        ),
      ],
    );
  }
}

class _Console extends StatelessWidget {
  const _Console({
    required this.selfName,
    required this.selfAddress,
    required this.dest,
    required this.others,
    required this.active,
    required this.phone,
    required this.onPick,
    required this.onSend,
    required this.onOpenTransfer,
    required this.burst,
  });
  final int burst;
  final String selfName;
  final String? selfAddress;
  final Device? dest;
  final List<Device> others;
  final TransferSnapshot? active;
  final bool phone;
  final ValueChanged<Device> onPick;
  final VoidCallback onSend;
  final VoidCallback? onOpenTransfer;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final a = active;
    final moving = a != null && (a.phase == TransferPhase.running || a.phase == TransferPhase.awaitingAcceptance);
    final progress = a == null || a.bytesTotal == 0 ? 0.0 : a.bytesDone / a.bytesTotal;
    final railState = a != null ? (moving ? RailState.moving : RailState.linked) : (dest != null ? RailState.linked : RailState.idle);
    final sending = a?.role != TransferRole.receiving;
    final farName = a?.peerName ?? dest?.name;
    final leftName = a != null && !sending ? a.peerName : selfName;
    final rightName = a != null && !sending ? selfName : farName;

    Widget endpoint({required String legend, required String? name, required bool lit, required bool end}) => Column(
          crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              ClayLamp(lit: lit),
              const SizedBox(width: 6),
              Flexible(child: Text(legend.toUpperCase(), style: t.micro.copyWith(letterSpacing: 1.2, color: SdColors.text3), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 6),
            Text(
              name ?? 'No one yet',
              style: (phone ? t.title : t.display).copyWith(color: name == null ? SdColors.text3 : SdColors.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: end ? TextAlign.end : TextAlign.start,
            ),
          ],
        );

    final readout = Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      if (a != null && moving) ...[
        Text((a.speed / 1e6).toStringAsFixed(1), style: phone ? t.numericMedium : t.numericHero),
        const SizedBox(width: 6),
        Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('MB/S', style: t.micro.copyWith(letterSpacing: 1.2, color: SdColors.text3))),
      ] else
        Flexible(
          child: Text(
            a != null ? (a.phase == TransferPhase.paused ? 'Paused' : 'Waiting') : (dest == null ? 'Nobody nearby yet' : 'Ready to send'),
            style: t.title.copyWith(color: SdColors.text2),
          ),
        ),
      const SizedBox(width: SdSpace.s3),
      Expanded(
        child: a == null
            ? const SizedBox.shrink()
            : Text(
                '${(progress * 100).floor()}%  ·  ${formatBytes(a.bytesDone)} of ${formatBytes(a.bytesTotal)}${a.etaSeconds != null && moving ? '  ·  ${formatRemaining(a.etaSeconds!)}' : ''}',
                style: t.numericSmall.copyWith(color: SdColors.text2),
                textAlign: TextAlign.end,
                maxLines: 2,
              ),
      ),
    ]);

    final destKeys = Wrap(spacing: SdSpace.s2, runSpacing: SdSpace.s2, alignment: phone ? WrapAlignment.center : WrapAlignment.end, children: [
      for (final d in others.take(5))
        ClayChoiceKey(
          label: d.name,
          icon: _glyph(d.kind),
          selected: d.id == dest?.id,
          onTap: () => onPick(d),
        ),
    ]);

    final controls = phone
        ? Column(children: [
            ClaySendKey(onPressed: onSend, size: 112),
            const SizedBox(height: SdSpace.s3),
            Text(dest == null ? 'Pick files; choose who gets them next' : 'Press to pick files for ${dest!.name}', style: t.caption, textAlign: TextAlign.center),
            if (others.isNotEmpty) ...[const SizedBox(height: SdSpace.s5), destKeys],
          ])
        : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            ClaySendKey(onPressed: onSend),
            const SizedBox(width: SdSpace.s5),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Send', style: t.title),
                const SizedBox(height: 2),
                Text(dest == null ? 'Pick files, then choose who gets them' : 'Drop files anywhere, or press the key. They go to ${dest!.name}.', style: t.caption),
              ]),
            ),
            const SizedBox(width: SdSpace.s4),
            Flexible(child: destKeys),
          ]);

    return ClaySurface(
      radius: 36,
      padding: EdgeInsets.all(phone ? SdSpace.s5 : SdSpace.s8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: endpoint(legend: a != null && !sending ? 'Sending' : 'This device', name: leftName, lit: true, end: false)),
          const SizedBox(width: SdSpace.s4),
          Expanded(
            child: endpoint(
              legend: a != null ? (sending ? 'Receiving' : 'This device') : (dest == null ? 'Destination' : 'Destination · ready'),
              name: rightName,
              lit: a != null || dest != null,
              end: true,
            ),
          ),
        ]),
        SizedBox(height: phone ? SdSpace.s5 : SdSpace.s8),
        readout,
        const SizedBox(height: SdSpace.s3),
        MouseRegion(
          cursor: onOpenTransfer == null ? MouseCursor.defer : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onOpenTransfer,
            child: Row(children: [
              ClayPuck(icon: _glyph(a != null && !sending ? a.peerKind : (phone ? DeviceKind.phone : DeviceKind.desktop)), lit: true, size: phone ? SdSpace.s12 : SdSpace.s16 + SdSpace.s3),
              const SizedBox(width: SdSpace.s3),
              Expanded(child: TransferRail(progress: progress, speed: a?.speed ?? 0, state: railState, objects: a == null ? 4 : a.filesTotal.clamp(1, 6), burst: burst)),
              const SizedBox(width: SdSpace.s3),
              ClayPuckSlot(
                id: a?.peerName ?? dest?.id ?? 'none',
                child: ClayPuck(
                  icon: _glyph(a != null && sending ? a.peerKind : (a != null ? (phone ? DeviceKind.phone : DeviceKind.desktop) : (dest?.kind ?? DeviceKind.phone))),
                  emptyIcon: SdIcons.send,
                  lit: a != null || dest != null,
                  empty: a == null && dest == null,
                  size: phone ? SdSpace.s12 : SdSpace.s16 + SdSpace.s3,
                  landing: burst,
                ),
              ),
            ]),
          ),
        ),
        if (selfAddress != null && a == null) ...[
          const SizedBox(height: SdSpace.s2),
          Text(selfAddress!, style: t.numericSmall.copyWith(color: SdColors.text3)),
        ],
        SizedBox(height: phone ? SdSpace.s6 : SdSpace.s8),
        controls,
      ]),
    );
  }
}

/// Recent transfers as an instrument log: one recessed well, mono columns, a green tick
/// for verified. Rows, not cards.
class _Log extends StatelessWidget {
  const _Log({required this.records, required this.onAll});
  final List<TransferRecord> records;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    String hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('LOG', style: t.micro.copyWith(letterSpacing: 1.6, color: SdColors.text3)),
        const Spacer(),
        if (records.isNotEmpty) ClayKey(label: 'All transfers', height: SdSpace.s10, onPressed: onAll),
      ]),
      const SizedBox(height: SdSpace.s3),
      ClayWell(
        radius: 22,
        padding: const EdgeInsets.symmetric(horizontal: SdSpace.s5, vertical: SdSpace.s3),
        child: records.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: SdSpace.s5),
                child: Text('Nothing moved yet. Your first transfer shows up here.', style: t.body.copyWith(color: SdColors.text3)),
              )
            : Column(children: [
                for (final (i, r) in records.indexed) ...[
                  if (i > 0) const Divider(height: 1, color: SdColors.hairline),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(children: [
                      SizedBox(width: 56, child: Text(hm(r.finishedAt), style: t.numericSmall.copyWith(color: SdColors.text3))),
                      Icon(r.role == TransferRole.sending ? SdIcons.sendUp : SdIcons.receiveDown, size: 16, color: SdColors.redOnDark),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${plural(r.fileCount, 'file')}  ${r.role == TransferRole.sending ? 'to' : 'from'} ${r.peerName}',
                          style: t.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(formatBytes(r.totalBytes), style: t.numericSmall.copyWith(color: SdColors.text2)),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 20,
                        child: r.outcome == TransferOutcome.completed
                            ? Icon(SdIcons.check, size: 16, color: r.verified ? Clay.green : SdColors.text2)
                            : const Icon(SdIcons.cancelled, size: 16, color: SdColors.text3),
                      ),
                    ]),
                  ),
                ],
              ]),
      ),
    ]);
  }
}

IconData _glyph(DeviceKind k) => k == DeviceKind.phone ? SdIcons.phone : SdIcons.devices;
