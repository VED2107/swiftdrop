/**
 * Adaptive concurrency + chunk-size controller.
 *
 * Goal: find the smallest number of parallel streams that saturates the link, then
 * hold there. More streams than that only adds contention, memory and latency.
 *
 * Streams — hill climbing with backoff:
 *   probe up one stream at a time while throughput improves by > `gainThreshold`;
 *   when a probe does not pay off, step back to the best level and hold;
 *   periodically re-probe (links change: someone else starts streaming on the Wi-Fi);
 *   on errors, halve (multiplicative decrease); on receiver pressure, drop one.
 *
 * Chunk size — latency targeting:
 *   a request should take roughly `targetLatencyMs`. Too short means per-request
 *   overhead dominates (grow); too long means coarse progress, slow recovery and
 *   more memory in flight (shrink). Always bounded by the memory budget.
 *
 * Pure and clock-free: feed it samples, read its decisions. That keeps it testable.
 */

export interface ControllerConfig {
  minStreams: number;
  maxStreams: number;
  initialStreams: number;
  minBlocks: number;
  maxBlocks: number;
  initialBlocks: number;
  blockSize: number;
  /** Upper bound on bytes buffered in flight (streams × chunk). iOS gets a small one. */
  memoryBudget: number;
  targetLatencyMs: [low: number, high: number];
  /** Relative throughput gain required to keep a probe. */
  gainThreshold: number;
  /** Samples to hold at the best level before re-probing. */
  holdSamples: number;
  /** Samples to wait after any change before judging it. */
  settleSamples: number;
}

export interface ControllerSample {
  /** bytes/s measured over the sample interval */
  throughput: number;
  /** mean request latency in the interval, ms (0 when no request finished) */
  avgLatencyMs: number;
  /** failed requests in the interval */
  errors: number;
  /** max receiver load hint in the interval, 0..1 */
  serverLoad: number;
}

export type ControllerReason =
  | "settling"
  | "probe-up"
  | "probe-kept"
  | "probe-reverted"
  | "hold"
  | "reprobe"
  | "errors"
  | "receiver-busy"
  | "idle";

export interface ControllerDecision {
  streams: number;
  blocksPerChunk: number;
  reason: ControllerReason;
}

export const DESKTOP_CONTROLLER: ControllerConfig = {
  minStreams: 1,
  maxStreams: 6, // browsers allow 6 HTTP/1.1 connections per host
  initialStreams: 3,
  minBlocks: 1,
  maxBlocks: 16,
  initialBlocks: 4,
  blockSize: 1 << 20,
  memoryBudget: 128 << 20,
  targetLatencyMs: [250, 900],
  gainThreshold: 0.05,
  holdSamples: 10,
  settleSamples: 1,
};

export const MOBILE_CONTROLLER: ControllerConfig = {
  ...DESKTOP_CONTROLLER,
  initialBlocks: 2,
  maxBlocks: 8,
  memoryBudget: 48 << 20,
};

export class AdaptiveController {
  readonly config: ControllerConfig;
  streams: number;
  blocksPerChunk: number;

  private phase: "probing" | "holding" = "probing";
  private baseline = 0; // throughput before the current probe
  private bestStreams: number;
  private bestThroughput = 0;
  private settle: number;
  private held = 0;
  private smoothed = 0;

  constructor(config: ControllerConfig) {
    this.config = config;
    this.streams = clamp(config.initialStreams, config.minStreams, config.maxStreams);
    this.blocksPerChunk = clamp(config.initialBlocks, config.minBlocks, config.maxBlocks);
    this.bestStreams = this.streams;
    this.settle = config.settleSamples;
    this.fitMemory();
  }

  update(s: ControllerSample): ControllerDecision {
    const c = this.config;
    // EWMA damps single-interval spikes so one lucky second doesn't lock in a level.
    this.smoothed = this.smoothed === 0 ? s.throughput : this.smoothed * 0.5 + s.throughput * 0.5;
    const tput = this.smoothed;

    if (s.errors > 0) {
      this.streams = Math.max(c.minStreams, Math.floor(this.streams / 2));
      this.blocksPerChunk = Math.max(c.minBlocks, Math.floor(this.blocksPerChunk / 2));
      return this.after("errors");
    }

    if (s.serverLoad >= 0.85) {
      this.streams = Math.max(c.minStreams, this.streams - 1);
      return this.after("receiver-busy");
    }

    if (s.throughput === 0 && s.avgLatencyMs === 0) {
      return this.decision("idle");
    }

    this.tuneChunk(s.avgLatencyMs);

    if (this.settle > 0) {
      this.settle--;
      return this.decision("settling");
    }

    if (this.phase === "probing") {
      if (this.baseline === 0) {
        // First judgement at the initial level: record and try one more stream.
        this.baseline = tput;
        this.recordBest(tput);
        return this.probeUp();
      }
      if (tput > this.baseline * (1 + c.gainThreshold)) {
        this.recordBest(tput);
        this.baseline = tput;
        if (this.streams < c.maxStreams) return this.probeUp();
        this.phase = "holding";
        this.held = 0;
        return this.decision("probe-kept");
      }
      // The extra stream didn't pay for itself: step back and hold.
      this.streams = this.bestStreams;
      this.phase = "holding";
      this.held = 0;
      return this.after("probe-reverted");
    }

    // holding
    if (tput > this.bestThroughput) this.bestThroughput = tput;
    // Sustained collapse at the held level means conditions changed: re-learn.
    if (tput < this.bestThroughput * 0.6) {
      this.bestThroughput = tput;
      this.baseline = tput;
      this.phase = "probing";
      if (this.streams > c.minStreams) this.streams--;
      return this.after("reprobe");
    }
    if (++this.held >= c.holdSamples && this.streams < c.maxStreams) {
      this.baseline = tput;
      this.phase = "probing";
      return this.probeUp("reprobe");
    }
    return this.decision("hold");
  }

  private probeUp(reason: ControllerReason = "probe-up"): ControllerDecision {
    if (this.streams >= this.config.maxStreams) {
      this.phase = "holding";
      this.held = 0;
      return this.decision("hold");
    }
    this.streams++;
    return this.after(reason);
  }

  private recordBest(tput: number) {
    if (tput >= this.bestThroughput) {
      this.bestThroughput = tput;
      this.bestStreams = this.streams;
    }
  }

  private tuneChunk(latency: number) {
    const c = this.config;
    if (latency <= 0) return;
    const [low, high] = c.targetLatencyMs;
    if (latency < low && this.blocksPerChunk < c.maxBlocks) this.blocksPerChunk *= 2;
    else if (latency > high * 2 && this.blocksPerChunk > c.minBlocks) this.blocksPerChunk = Math.ceil(this.blocksPerChunk / 2);
    this.blocksPerChunk = clamp(this.blocksPerChunk, c.minBlocks, c.maxBlocks);
    this.fitMemory();
  }

  private fitMemory() {
    const c = this.config;
    while (this.streams * this.blocksPerChunk * c.blockSize > c.memoryBudget && this.blocksPerChunk > c.minBlocks) {
      this.blocksPerChunk = Math.max(c.minBlocks, Math.floor(this.blocksPerChunk / 2));
    }
  }

  private after(reason: ControllerReason): ControllerDecision {
    this.settle = this.config.settleSamples;
    // A new level gets a fresh measurement; carrying the old average would fake a gain.
    this.smoothed = 0;
    this.fitMemory();
    return this.decision(reason);
  }

  private decision(reason: ControllerReason): ControllerDecision {
    return { streams: this.streams, blocksPerChunk: this.blocksPerChunk, reason };
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}
