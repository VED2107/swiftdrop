/// Adaptive concurrency + chunk-size controller. Line-for-line port of
/// `packages/transfer-engine/src/controller.ts` (see there for the reasoning); the
/// cross-language vectors replay the same samples through both and compare decisions.
///
/// Streams: hill-climb one at a time while throughput improves > gainThreshold, revert
/// to the best level when a probe doesn't pay, re-probe periodically, halve on errors,
/// drop one on receiver pressure. Chunk size: target a request latency band, bounded by
/// the memory budget. Judgements use windows of ≥ minCompletions finished requests.
/// Pure and clock-free.
library;

class ControllerConfig {
  const ControllerConfig({
    required this.minStreams,
    required this.maxStreams,
    required this.initialStreams,
    required this.minBlocks,
    required this.maxBlocks,
    required this.initialBlocks,
    required this.blockSize,
    required this.memoryBudget,
    required this.targetLatencyLow,
    required this.targetLatencyHigh,
    required this.gainThreshold,
    required this.holdSamples,
    required this.minCompletions,
    required this.maxWindowSamples,
    required this.settleSamples,
  });

  final int minStreams;
  final int maxStreams;
  final int initialStreams;
  final int minBlocks;
  final int maxBlocks;
  final int initialBlocks;
  final int blockSize;

  /// Upper bound on bytes in flight (streams × chunk).
  final int memoryBudget;
  final double targetLatencyLow;
  final double targetLatencyHigh;
  final double gainThreshold;
  final int holdSamples;
  final int minCompletions;
  final int maxWindowSamples;
  final int settleSamples;

  ControllerConfig copyWith({int? maxStreams, int? initialStreams, int? initialBlocks, int? maxBlocks, int? memoryBudget}) => ControllerConfig(
        minStreams: minStreams,
        maxStreams: maxStreams ?? this.maxStreams,
        initialStreams: initialStreams ?? this.initialStreams,
        minBlocks: minBlocks,
        maxBlocks: maxBlocks ?? this.maxBlocks,
        initialBlocks: initialBlocks ?? this.initialBlocks,
        blockSize: blockSize,
        memoryBudget: memoryBudget ?? this.memoryBudget,
        targetLatencyLow: targetLatencyLow,
        targetLatencyHigh: targetLatencyHigh,
        gainThreshold: gainThreshold,
        holdSamples: holdSamples,
        minCompletions: minCompletions,
        maxWindowSamples: maxWindowSamples,
        settleSamples: settleSamples,
      );
}

const desktopController = ControllerConfig(
  minStreams: 1,
  maxStreams: 6,
  initialStreams: 3,
  minBlocks: 1,
  maxBlocks: 16,
  initialBlocks: 4,
  blockSize: 1 << 20,
  memoryBudget: 128 << 20,
  targetLatencyLow: 250,
  targetLatencyHigh: 900,
  gainThreshold: 0.05,
  holdSamples: 10,
  settleSamples: 1,
  minCompletions: 6,
  maxWindowSamples: 4,
);

const mobileController = ControllerConfig(
  minStreams: 1,
  maxStreams: 6,
  initialStreams: 3,
  minBlocks: 1,
  maxBlocks: 8,
  initialBlocks: 2,
  blockSize: 1 << 20,
  memoryBudget: 48 << 20,
  targetLatencyLow: 250,
  targetLatencyHigh: 900,
  gainThreshold: 0.05,
  holdSamples: 10,
  settleSamples: 1,
  minCompletions: 6,
  maxWindowSamples: 4,
);

class ControllerSample {
  const ControllerSample({
    required this.throughput,
    required this.avgLatencyMs,
    required this.completed,
    this.errors = 0,
    this.serverLoad = 0,
  });

  /// bytes/s over the sample interval
  final double throughput;

  /// mean request latency, ms (0 when none finished)
  final double avgLatencyMs;
  final int completed;
  final int errors;

  /// max receiver load hint, 0..1
  final double serverLoad;
}

enum ControllerReason {
  settling('settling'),
  measuring('measuring'),
  probeUp('probe-up'),
  probeKept('probe-kept'),
  probeReverted('probe-reverted'),
  hold('hold'),
  reprobe('reprobe'),
  errors('errors'),
  receiverBusy('receiver-busy'),
  idle('idle');

  const ControllerReason(this.wire);
  final String wire;
}

class ControllerDecision {
  const ControllerDecision(this.streams, this.blocksPerChunk, this.reason);
  final int streams;
  final int blocksPerChunk;
  final ControllerReason reason;
}

class AdaptiveController {
  AdaptiveController(this.config)
      : streams = _clamp(config.initialStreams, config.minStreams, config.maxStreams),
        blocksPerChunk = _clamp(config.initialBlocks, config.minBlocks, config.maxBlocks),
        _settle = config.settleSamples {
    _bestStreams = streams;
    _fitMemory();
  }

  final ControllerConfig config;
  int streams;
  int blocksPerChunk;

  bool _probing = true;
  double _baseline = 0;
  late int _bestStreams;
  double _bestThroughput = 0;
  int _settle;
  int _held = 0;
  double _wSum = 0;
  int _wSamples = 0;
  int _wCompleted = 0;

  ControllerDecision update(ControllerSample s) {
    final c = config;
    if (s.errors > 0) {
      streams = _max(c.minStreams, streams ~/ 2);
      blocksPerChunk = _max(c.minBlocks, blocksPerChunk ~/ 2);
      return _after(ControllerReason.errors);
    }
    if (s.serverLoad >= 0.85) {
      streams = _max(c.minStreams, streams - 1);
      return _after(ControllerReason.receiverBusy);
    }
    if (s.throughput == 0 && s.avgLatencyMs == 0) return _decision(ControllerReason.idle);

    _tuneChunk(s.avgLatencyMs);

    if (_settle > 0) {
      _settle--;
      return _decision(ControllerReason.settling);
    }

    _wSum += s.throughput;
    _wSamples++;
    _wCompleted += s.completed;
    if (_wCompleted < c.minCompletions && _wSamples < c.maxWindowSamples) return _decision(ControllerReason.measuring);
    final tput = _wSum / _wSamples;
    _resetWindow();

    if (_probing) {
      if (_baseline == 0) {
        _baseline = tput;
        _recordBest(tput);
        return _probeUp();
      }
      if (tput > _baseline * (1 + c.gainThreshold)) {
        _recordBest(tput);
        _baseline = tput;
        if (streams < c.maxStreams) return _probeUp();
        _probing = false;
        _held = 0;
        return _decision(ControllerReason.probeKept);
      }
      streams = _bestStreams;
      _probing = false;
      _held = 0;
      return _after(ControllerReason.probeReverted);
    }

    if (tput > _bestThroughput) _bestThroughput = tput;
    if (tput < _bestThroughput * 0.6) {
      _bestThroughput = tput;
      _baseline = tput;
      _probing = true;
      if (streams > c.minStreams) streams--;
      return _after(ControllerReason.reprobe);
    }
    if (++_held >= c.holdSamples && streams < c.maxStreams) {
      _baseline = tput;
      _probing = true;
      return _probeUp(ControllerReason.reprobe);
    }
    return _decision(ControllerReason.hold);
  }

  ControllerDecision _probeUp([ControllerReason reason = ControllerReason.probeUp]) {
    if (streams >= config.maxStreams) {
      _probing = false;
      _held = 0;
      return _decision(ControllerReason.hold);
    }
    streams++;
    return _after(reason);
  }

  void _recordBest(double tput) {
    if (tput >= _bestThroughput) {
      _bestThroughput = tput;
      _bestStreams = streams;
    }
  }

  void _tuneChunk(double latency) {
    final c = config;
    if (latency <= 0) return;
    if (latency < c.targetLatencyLow && blocksPerChunk < c.maxBlocks) {
      blocksPerChunk *= 2;
    } else if (latency > c.targetLatencyHigh * 2 && blocksPerChunk > c.minBlocks) {
      blocksPerChunk = (blocksPerChunk + 1) ~/ 2;
    }
    blocksPerChunk = _clamp(blocksPerChunk, c.minBlocks, c.maxBlocks);
    _fitMemory();
  }

  void _fitMemory() {
    final c = config;
    while (streams * blocksPerChunk * c.blockSize > c.memoryBudget && blocksPerChunk > c.minBlocks) {
      blocksPerChunk = _max(c.minBlocks, blocksPerChunk ~/ 2);
    }
  }

  ControllerDecision _after(ControllerReason reason) {
    _settle = config.settleSamples;
    _resetWindow();
    _fitMemory();
    return _decision(reason);
  }

  void _resetWindow() {
    _wSum = 0;
    _wSamples = 0;
    _wCompleted = 0;
  }

  ControllerDecision _decision(ControllerReason reason) => ControllerDecision(streams, blocksPerChunk, reason);
}

int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
int _max(int a, int b) => a > b ? a : b;

/// WebRTC DataChannel links (one SCTP channel between phones), as `PEER_CONTROLLER`.
const peerController = ControllerConfig(
  minStreams: 1,
  maxStreams: 4,
  initialStreams: 2,
  minBlocks: 1,
  maxBlocks: 4,
  initialBlocks: 1,
  blockSize: 1 << 20,
  memoryBudget: 16 << 20,
  targetLatencyLow: 150,
  targetLatencyHigh: 900,
  gainThreshold: 0.05,
  holdSamples: 10,
  settleSamples: 1,
  minCompletions: 6,
  maxWindowSamples: 4,
);

/// Controller for a laned native transport: the request window scales with the lanes so
/// every connection can keep requests queued; the memory budget stays the platform's.
ControllerConfig lanedController(ControllerConfig base, int lanes) => lanes <= 1
    ? base
    : base.copyWith(maxStreams: base.maxStreams * lanes, initialStreams: base.initialStreams * lanes);
