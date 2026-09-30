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
import 'transfer_rows.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider).value ?? const <TransferRecord>[];
    final live = (ref.watch(transfersProvider).value ?? const <TransferSnapshot>[]).where((t) => !t.phase.isFinished).toList();
    final groups = groupByDay(history, DateTime.now());
    final desktop = !(Platform.isAndroid || Platform.isIOS);

    void menu(TransferRecord r, Offset at) => showGlassMenu(context, at, [
          if (desktop && r.location != null)
            (label: 'Show in folder', icon: SdIcons.openFolder, onTap: () => revealFolder(r.location!), danger: false),
          (label: 'Remove from history', icon: SdIcons.forget, onTap: () => ref.read(transferHistoryProvider).remove(r.transferId), danger: true),
        ]);

    return ScreenFrame(
      title: 'Transfers',
      actions: [
        if (history.isNotEmpty)
          GlassButton(
            label: 'Clear history',
            kind: GlassButtonKind.quiet,
            compact: true,
            onPressed: () async {
              final ok = await confirmSheet(
                context,
                title: 'Clear history?',
                message: 'Only the list is cleared. Files you received stay where they are.',
                confirm: 'Clear history',
              );
              if (ok) await ref.read(transferHistoryProvider).clear();
            },
          ),
      ],
      children: [
        if (live.isNotEmpty) ...[
          const SectionHeader('Now'),
          for (final t in live) ...[
            TransferGlassCard(transfer: t, onOpen: () => context.push(Routes.transfer(t.transferId))),
            const SizedBox(height: SdSpace.s3),
          ],
        ],
        if (history.isEmpty && live.isEmpty) ...[
          const SizedBox(height: SdSpace.s6),
          const EmptyState(
            icon: SdIcons.transfers,
            title: 'No transfers yet',
            message: 'Everything you send or receive is listed here, with its size, speed and whether every file arrived intact.',
          ),
        ],
        for (final g in groups) ...[SectionHeader(g.label), TransferRecordGroup(records: g.records, onSecondary: menu)],
      ],
    );
  }
}

class DayGroup {
  const DayGroup(this.label, this.records);
  final String label;
  final List<TransferRecord> records;
}

/// Today / Yesterday / Earlier, newest first, empty groups omitted.
List<DayGroup> groupByDay(List<TransferRecord> records, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final buckets = {'Today': <TransferRecord>[], 'Yesterday': <TransferRecord>[], 'Earlier': <TransferRecord>[]};
  for (final r in records) {
    final d = r.finishedAt;
    final day = DateTime(d.year, d.month, d.day);
    buckets[day == today ? 'Today' : (day == yesterday ? 'Yesterday' : 'Earlier')]!.add(r);
  }
  return [
    for (final e in buckets.entries)
      if (e.value.isNotEmpty) DayGroup(e.key, e.value..sort((a, b) => b.finishedAt.compareTo(a.finishedAt))),
  ];
}
