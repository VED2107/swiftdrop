import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../design/design.dart';

/// History rows on one quiet surface, hairline-separated. Numbers are tabular. A row that
/// didn't complete says what happened, in words.
class TransferRecordGroup extends StatelessWidget {
  const TransferRecordGroup({super.key, required this.records, this.onSecondary});
  final List<TransferRecord> records;

  /// Right-click / long-press on a row (context menu).
  final void Function(TransferRecord r, Offset globalPosition)? onSecondary;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      level: GlassLevel.regular,
      child: Column(children: [
        for (var i = 0; i < records.length; i++) ...[
          if (i > 0) const Divider(height: 1, thickness: 1, indent: SdSpace.s4 + 40, color: SdColors.hairline),
          GestureDetector(
            onSecondaryTapUp: onSecondary == null ? null : (d) => onSecondary!(records[i], d.globalPosition),
            onLongPressStart: onSecondary == null ? null : (d) => onSecondary!(records[i], d.globalPosition),
            child: _RecordRow(record: records[i]),
          ),
        ],
      ]),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record});
  final TransferRecord record;

  @override
  Widget build(BuildContext context) {
    final t = context.sdText;
    final r = record;
    final ok = r.outcome == TransferOutcome.completed;
    final direction = r.role == TransferRole.sending ? 'To ${r.peerName}' : 'From ${r.peerName}';
    final outcome = switch (r.outcome) {
      TransferOutcome.completed => r.verified ? 'Verified' : 'Completed',
      TransferOutcome.failed => 'Didn’t finish: the connection or a file changed. Send again to continue.',
      TransferOutcome.cancelled => 'Cancelled',
      TransferOutcome.declined => 'Declined by ${r.peerName}',
    };
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SdSpace.s4, vertical: SdSpace.s3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 28,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                switch (r.outcome) {
                  TransferOutcome.completed => SdIcons.check,
                  TransferOutcome.failed => SdIcons.failed,
                  TransferOutcome.cancelled || TransferOutcome.declined => SdIcons.cancelled,
                },
                size: 18,
                color: ok ? SdColors.redOnDark : (r.outcome == TransferOutcome.failed ? SdColors.warning : SdColors.text3),
              ),
            ),
          ),
          const SizedBox(width: SdSpace.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${plural(r.fileCount, 'file')} · ${formatBytes(r.totalBytes)}', style: t.bodyStrong.copyWith(fontFeatures: t.numeric.fontFeatures)),
              const SizedBox(height: 2),
              Text(direction, style: t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(outcome, style: t.caption.copyWith(color: ok ? SdColors.text2 : SdColors.text3)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(_time(r.finishedAt), style: t.numericSmall),
            if (r.averageSpeed != null && ok) Text(formatRate(r.averageSpeed!), style: t.numericSmall.copyWith(color: SdColors.text3)),
          ]),
        ]),
      ),
    );
  }

  static String _time(DateTime d) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (d.year == now.year && d.month == now.month && d.day == now.day) return '${two(d.hour)}:${two(d.minute)}';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]}';
  }
}
