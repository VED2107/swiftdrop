import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../app/providers.dart';
import '../../design/design.dart';
import '../screen_frame.dart';
import 'transfer_rows.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider).value ?? const <TransferRecord>[];
    final groups = groupByDay(history, DateTime.now());
    return ScreenFrame(
      title: 'Transfers',
      children: [
        if (history.isEmpty) ...[
          const SizedBox(height: SdSpace.s6),
          const EmptyState(
            icon: SdIcons.transfers,
            title: 'No transfers yet',
            message: 'Everything you send or receive is listed here, with its size, speed and whether it arrived intact.',
          ),
        ],
        for (final g in groups) ...[SectionHeader(g.label), TransferRecordGroup(records: g.records)],
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
