import 'package:swiftdrop_core/swiftdrop_core.dart';
import 'package:test/test.dart';

void main() {
  test('formatBytes matches packages/shared', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(-5), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1000), '1.0 KB');
    expect(formatBytes(1536000), '1.5 MB');
    expect(formatBytes(123456789), '123 MB');
    expect(formatBytes(1.8e9), '1.8 GB');
    expect(formatRate(94e6), '94.0 MB/s');
  });

  test('durations', () {
    expect(formatDuration(72), '01:12');
    expect(formatDuration(3723), '1:02:03');
    expect(formatDuration(-1), '--:--');
    expect(formatRemaining(72), '1m 12s');
    expect(formatRemaining(3), 'a few seconds');
    expect(formatRemaining(7500), '2h 5m');
  });

  test('counts', () {
    expect(formatCount(10000), '10,000');
    expect(plural(1, 'file'), '1 file');
    expect(plural(24, 'file'), '24 files');
  });
}
