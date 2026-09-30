import 'dart:collection';

/// Rolling-window throughput meter. Port of `speed-meter.ts`: bytes summed over a sliding
/// window divided by its span, so lumpy completions (16 MiB at once) read as a steady rate.
class SpeedMeter {
  SpeedMeter({this.windowMs = 3000, required this.now});

  final double windowMs;
  final double Function() now;
  final _events = ListQueue<(double, int)>();
  int _windowSum = 0;
  double _startedAt = -1;
  double _activeMs = 0;
  double _resumedAt = -1;
  int total = 0;
  double peak = 0;

  /// Marks the meter active (time counts toward the average).
  void start() {
    final t = now();
    if (_startedAt < 0) _startedAt = t;
    if (_resumedAt < 0) _resumedAt = t;
  }

  /// Marks the meter idle (paused, reconnecting) so the average stays honest.
  void stop() {
    if (_resumedAt >= 0) {
      _activeMs += now() - _resumedAt;
      _resumedAt = -1;
    }
    _events.clear();
    _windowSum = 0;
  }

  void add(int bytes) {
    _events.add((now(), bytes));
    _windowSum += bytes;
    total += bytes;
  }

  /// Bytes/second over the rolling window. Also updates [peak].
  double rate() {
    final t = now();
    final cutoff = t - windowMs;
    while (_events.isNotEmpty && _events.first.$1 <= cutoff) {
      _windowSum -= _events.removeFirst().$2;
    }
    if (_resumedAt < 0) return 0;
    final span = (t - _resumedAt).clamp(500.0, windowMs);
    final r = _windowSum * 1000 / span;
    // Peak ignores the first moments of a run, when one early chunk can fake a spike.
    if (t - _resumedAt >= (windowMs < 1500 ? windowMs : 1500) && r > peak) peak = r;
    return r;
  }

  /// Average over active time only.
  double average() {
    final active = _activeMs + (_resumedAt >= 0 ? now() - _resumedAt : 0);
    return active > 0 ? total * 1000 / active : 0;
  }

  double get activeSeconds => (_activeMs + (_resumedAt >= 0 ? now() - _resumedAt : 0)) / 1000;
}
