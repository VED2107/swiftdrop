import 'package:flutter/material.dart';
import 'package:swiftdrop_core/swiftdrop_core.dart';

import '../../design/design.dart';

/// History rows grouped on one surface (G1), hairline-separated. Numbers are tabular.
class TransferRecordGroup extends StatelessWidget {
  const TransferRecordGroup({super.key, required this.records});
  final List<TransferRecord> records;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      level: GlassLevel.surface,
      child: Column(children: [
        for (var i = 0; i < records.length; i++) ...[
          if (i > 0) const Divider(height: 1, thickness: 1, indent: SdSpace.s4 + 40, color: SdColors.hairline),
          _RecordRow(record: records[i]),
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
      TransferOutcome.failed => 'Failed',
      TransferOutcome.cancelled => 'Cancelled',
      TransferOutcome.declined => 'Declined',
    };
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SdSpace.s4, vertical: SdSpace.s3),
        child: Row(children: [
          SizedBox(
            width: 28,
            child: Icon(
              switch (r.outcome) {
                TransferOutcome.completed => SdIcons.check,
                TransferOutcome.failed => SdIcons.failed,
                TransferOutcome.cancelled || TransferOutcome.declined => SdIcons.cancelled,
              },
              size: 18,
              color: ok ? SdColors.redOnDark : SdColors.text3,
            ),
          ),
          const SizedBox(width: SdSpace.s3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${plural(r.fileCount, 'file')} · ${formatBytes(r.totalBytes)}', style: t.bodyStrong.copyWith(fontFeatures: t.numeric.fontFeatures)),
              const SizedBox(height: 2),
              Text('$direction · $outcome', style: t.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (r.averageSpeed != null) Text(formatRate(r.averageSpeed!), style: t.numericSmall),
        ]),
      ),
    );
  }
}
