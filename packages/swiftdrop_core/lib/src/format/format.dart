/// Display formatting shared by every surface. Same rules as `packages/shared/src/format.ts`:
/// decimal units (1 MB = 10^6 B), matching Explorer, Finder and how Wi-Fi is marketed.
library;

const _units = ['B', 'KB', 'MB', 'GB', 'TB'];

String formatBytes(num bytes, {int digits = 1}) {
  if (!bytes.isFinite || bytes <= 0) return '0 B';
  var i = 0;
  var v = bytes.toDouble();
  while (v >= 1000 && i < _units.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 || v >= 100 ? 0 : digits)} ${_units[i]}';
}

String formatRate(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// Compact clock form, like the web app: `01:12`, `1:02:03`, `--:--` when unknown.
String formatDuration(num seconds) {
  if (!seconds.isFinite || seconds < 0) return '--:--';
  final s = seconds.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

/// Spoken form for remaining time: `1m 12s`, `2h 5m`, `a few seconds`.
String formatRemaining(num seconds) {
  if (!seconds.isFinite || seconds < 0) return '';
  final s = seconds.round();
  if (s < 5) return 'a few seconds';
  if (s < 60) return '${s}s';
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (h > 0) return m > 0 ? '${h}h ${m}m' : '${h}h';
  final sec = s % 60;
  return sec > 0 ? '${m}m ${sec}s' : '${m}m';
}

/// `1,234` style grouping.
String formatCount(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

String plural(int n, String one, [String? many]) => '${formatCount(n)} ${n == 1 ? one : (many ?? '${one}s')}';
