import { bytesToBase64Url, createBlockHasher, HASH_LENGTH, randomToken, type BlockHasher, type HashAlgo } from "@swiftdrop/crypto";
import {
  BLOCK_SIZE,
  encodeBatchHeader,
  PROTOCOL_VERSION,
  userMessageFor,
  type Conflict,
  type ConflictPolicy,
  type Direction,
  type ErrorCode,
  type TransferStatus,
} from "@swiftdrop/protocol";
import { Bitset, Reservoir } from "@swiftdrop/shared";
import { AdaptiveController, DESKTOP_CONTROLLER, type ControllerConfig, type ControllerReason } from "./controller.ts";
import { Planner, type PlanFile, type WorkItem } from "./planner.ts";
import { SpeedMeter } from "./speed-meter.ts";
import { emptyStages, type Telemetry } from "./telemetry.ts";
import { TransportError, type Transport } from "./transport.ts";

export interface SourceFile {
  id: string;
  name: string;
  relDir: string;
  size: number;
  type: string;
  lastModified: number;
  blob: Blob;
}

export type ConflictDecision = "replace" | "skip" | "keep-both";

export interface JobOptions {
  transport: Transport;
  files: SourceFile[];
  direction: Direction;
  label: string;
  transferId?: string;
  integrity?: HashAlgo;
  onConflict?: ConflictPolicy;
  /** Called when the receiver reports name clashes. Return null to cancel. */
  resolveConflicts?: (conflicts: Conflict[]) => Promise<Record<string, ConflictDecision> | null>;
  controller?: ControllerConfig;
  bench?: boolean;
  sampleIntervalMs?: number;
  now?: () => number;
}

export type JobState =
  | "queued"
  | "preparing"
  | "awaiting-decision"
  | "running"
  | "paused"
  | "reconnecting"
  | "complete"
  | "failed"
  | "cancelled";

export type Health = "excellent" | "good" | "fair" | "poor" | "offline";

export interface JobSnapshot {
  transferId: string;
  label: string;
  direction: Direction;
  state: JobState;
  errorCode: ErrorCode | null;
  message: string | null;
  bytesDone: number;
  bytesTotal: number;
  filesDone: number;
  filesSkipped: number;
  filesFailed: number;
  filesTotal: number;
  speed: number;
  average: number;
  peak: number;
  filesPerSecond: number;
  etaSeconds: number;
  streams: number;
  chunkBytes: number;
  inflight: number;
  retries: number;
  chunkFailures: number;
  reconnects: number;
  rttMs: number | null;
  health: Health;
  lastDecision: ControllerReason | null;
  elapsedSeconds: number;
}

interface Flight {
  item: WorkItem;
  ac: AbortController;
  startedAt: number;
  /** payload bytes this request carries (for the in-flight window) */
  bytes: number;
  /** set when we aborted it on purpose (pause/cancel/reconnect) */
  intentional: boolean;
}

interface HashStore {
  digests: Uint8Array;
  known: Bitset;
}

const MAX_STRIKES = 5;
const STALL_MESSAGE_AFTER_MS = 60_000;

/**
 * One transfer: a set of files moving to one receiver.
 *
 * Event-driven scheduler: `pump()` keeps `controller.streams` requests in flight.
 * Every completion pumps again, every sample tick may widen or narrow the window.
 * The UI polls `snapshot()` on its own clock; nothing here renders or logs per chunk.
 */
export class TransferJob {
  readonly id: string;
  readonly label: string;
  readonly direction: Direction;
  readonly files: SourceFile[];
  readonly bytesTotal: number;

  private readonly opts: JobOptions;
  private readonly transport: Transport;
  private readonly now: () => number;
  private readonly controller: AdaptiveController;
  private readonly planner: Planner;
  private readonly meter: SpeedMeter;
  private readonly fileMeter: SpeedMeter;
  private readonly flights = new Set<Flight>();
  private readonly hashes = new Map<number, HashStore>();
  private readonly listeners = new Set<(job: TransferJob) => void>();
  private hasher: BlockHasher | null = null;

  // telemetry
  private readonly stages = emptyStages();
  private readonly tputSamples = new Reservoir(600);
  private readonly latencies = new Reservoir(512);
  private requests = 0;
  private prepareMs = 0;
  private wireBytes = 0;
  private inflightBytes = 0;
  private peakInflightBytes = 0;

  private _state: JobState = "queued";
  private errorCode: ErrorCode | null = null;
  private bytesDone = 0;
  private filesDone = 0;
  private filesSkipped = 0;
  private retries = 0;
  private chunkFailures = 0;
  private reconnects = 0;
  private consecutiveServerErrors = 0;
  private rtt: number | null = null;
  private lastDecision: ControllerReason | null = null;
  private reconnectingSince = 0;

  // per-sample accumulators
  private sampleTimer: ReturnType<typeof setInterval> | null = null;
  private sampleStart = 0;
  private sampleBytes = 0;
  private sampleLatencySum = 0;
  private sampleLatencyCount = 0;
  private sampleErrors = 0;
  private sampleLoad = 0;
  private recentErrors: number[] = [];

  private resolveDone!: () => void;
  readonly done: Promise<void>;

  constructor(opts: JobOptions) {
    this.opts = opts;
    this.transport = opts.transport;
    this.now = opts.now ?? (() => performance.now());
    this.id = opts.transferId ?? `tr_${randomToken(12)}`;
    this.label = opts.label;
    this.direction = opts.direction;
    this.files = opts.files;
    this.bytesTotal = opts.files.reduce((s, f) => s + f.size, 0);
    this.controller = new AdaptiveController(opts.controller ?? DESKTOP_CONTROLLER);
    this.planner = new Planner(opts.files, BLOCK_SIZE);
    this.meter = new SpeedMeter(3000, this.now);
    this.fileMeter = new SpeedMeter(3000, this.now);
    this.done = new Promise((r) => (this.resolveDone = r));
  }

  get state(): JobState {
    return this._state;
  }

  onChange(fn: (job: TransferJob) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  /** Round-trip time measured by someone with a free connection (the UI's WebSocket). */
  setRtt(ms: number): void {
    this.rtt = this.rtt === null ? ms : this.rtt * 0.7 + ms * 0.3;
  }

  async start(): Promise<void> {
    if (this._state !== "queued") return;
    this.setState("preparing");
    try {
      const t0 = this.now();
      this.hasher = await createBlockHasher(this.opts.integrity ?? "xxh64");
      const status = await this.negotiate();
      this.prepareMs = this.now() - t0;
      if (!status) return;
      this.adopt(status);
      this.run();
    } catch (err) {
      this.handleFatal(err);
    }
  }

  pause(): void {
    if (this._state !== "running" && this._state !== "reconnecting") return;
    this.abortAll();
    this.meter.stop();
    this.fileMeter.stop();
    this.stopSampling();
    this.setState("paused");
  }

  resume(): void {
    if (this._state !== "paused" && this._state !== "failed") return;
    this.errorCode = null;
    void this.reconnect(false);
  }

  async cancel(): Promise<void> {
    if (this._state === "complete" || this._state === "cancelled") return;
    this.abortAll();
    this.stopSampling();
    this.meter.stop();
    this.setState("cancelled");
    this.resolveDone();
    try {
      await this.transport.cancel(this.id);
    } catch {
      /* receiver may already be gone; nothing to clean up then */
    }
  }

  /** Re-queue files that exhausted their retries. */
  retryFailed(): void {
    let any = false;
    for (const f of this.planner.files) {
      if (f.state === "failed") {
        f.strikes = 0;
        this.planner.resetFile(f);
        any = true;
      }
    }
    if (any && (this._state === "failed" || this._state === "paused")) {
      this.errorCode = null;
      void this.reconnect(false);
    }
  }

  snapshot(): JobSnapshot {
    const running = this._state === "running";
    const speed = running ? this.meter.rate() : 0;
    const average = this.meter.average();
    const remaining = Math.max(0, this.bytesTotal - this.bytesDone);
    // Blend: the window reacts, the average steadies the ETA.
    const basis = speed > 0 ? speed * 0.7 + average * 0.3 : average;
    const failed = this.planner.files.reduce((n, f) => n + (f.state === "failed" ? 1 : 0), 0);
    return {
      transferId: this.id,
      label: this.label,
      direction: this.direction,
      state: this._state,
      errorCode: this.errorCode,
      message: this.message(),
      bytesDone: this.bytesDone,
      bytesTotal: this.bytesTotal,
      filesDone: this.filesDone,
      filesSkipped: this.filesSkipped,
      filesFailed: failed,
      filesTotal: this.files.length,
      speed,
      average,
      peak: this.meter.peak,
      filesPerSecond: running ? this.fileMeter.rate() : 0,
      etaSeconds: remaining === 0 ? 0 : basis > 0 ? remaining / basis : Infinity,
      streams: this.controller.streams,
      chunkBytes: this.controller.blocksPerChunk * BLOCK_SIZE,
      inflight: this.flights.size,
      retries: this.retries,
      chunkFailures: this.chunkFailures,
      reconnects: this.reconnects,
      rttMs: this.rtt,
      health: this.health(speed),
      lastDecision: this.lastDecision,
      elapsedSeconds: this.meter.activeSeconds,
    };
  }

  /** Per-file progress for detail views; cheap enough to call for a visible page of rows. */
  fileProgress(index: number): { state: PlanFile["state"]; bytes: number; finalName?: string } {
    const f = this.planner.files[index]!;
    return { state: f.state, bytes: this.planner.ackedBytes(f), ...(f.finalName ? { finalName: f.finalName } : {}) };
  }

  /** Where time and bytes go. Cheap; the dev performance panel polls it. */
  telemetry(): Telemetry {
    return {
      stages: { ...this.stages },
      prepareMs: this.prepareMs,
      requests: this.requests,
      payloadBytes: this.bytesDone,
      wireBytes: this.wireBytes,
      inflightBytes: this.inflightBytes,
      peakInflightBytes: this.peakInflightBytes,
      throughputP50: this.tputSamples.percentile(50),
      throughputP95: this.tputSamples.percentile(95),
      latencyP50: this.latencies.percentile(50),
      latencyP95: this.latencies.percentile(95),
    };
  }

  // -------------------------------------------------------------------------

  private async negotiate(): Promise<TransferStatus | null> {
    const base = {
      protocol: PROTOCOL_VERSION,
      transferId: this.id,
      direction: this.direction,
      label: this.label,
      integrity: this.hasher!.algo,
      onConflict: this.opts.onConflict ?? (this.opts.resolveConflicts ? "ask" : "keep-both"),
      bench: this.opts.bench ?? false,
      files: this.files.map((f) => ({
        id: f.id,
        name: f.name,
        relDir: f.relDir,
        size: f.size,
        type: f.type,
        lastModified: Math.max(0, Math.floor(f.lastModified)),
      })),
    };
    const first = await this.transport.create(base);
    if ("status" in first) return first.status;
    this.setState("awaiting-decision");
    const decisions = await this.opts.resolveConflicts!(first.conflicts);
    if (!decisions) {
      await this.cancel();
      return null;
    }
    const second = await this.transport.create({ ...base, onConflict: "keep-both", decisions });
    if (!("status" in second)) throw new TransportError("BAD_REQUEST");
    return second.status;
  }

  private adopt(status: TransferStatus) {
    this.planner.applyStatus(status);
    this.bytesDone = 0;
    this.filesDone = 0;
    this.filesSkipped = 0;
    for (const f of this.planner.files) {
      if (f.state === "skipped") this.filesSkipped++;
      else {
        this.bytesDone += this.planner.ackedBytes(f);
        if (f.state === "complete") this.filesDone++;
      }
    }
  }

  private run() {
    this.setState("running");
    this.meter.start();
    this.fileMeter.start();
    this.startSampling();
    this.pump();
  }

  private pump() {
    if (this._state !== "running") return;
    while (this.flights.size < this.controller.streams) {
      const item = this.planner.next(this.controller.blocksPerChunk);
      if (!item) break;
      this.launch(item);
    }
    if (this.flights.size === 0 && this.planner.finished) this.finish();
  }

  private launch(item: WorkItem) {
    const bytes = itemBytes(item, this.files);
    const flight: Flight = { item, ac: new AbortController(), startedAt: this.now(), bytes, intentional: false };
    this.flights.add(flight);
    this.inflightBytes += bytes;
    if (this.inflightBytes > this.peakInflightBytes) this.peakInflightBytes = this.inflightBytes;
    this.execute(flight)
      .catch((err: unknown) => this.onFlightError(flight, err))
      .finally(() => {
        this.flights.delete(flight);
        this.inflightBytes -= flight.bytes;
        this.pump();
      });
  }

  private async execute(flight: Flight): Promise<void> {
    const { item } = flight;
    const hasher = this.hasher!;
    const st = this.stages;
    if (item.kind === "complete") {
      const t0 = this.now();
      await this.completeFile(item);
      st.completeMs += this.now() - t0;
      return;
    }
    if (item.kind === "blocks") {
      const src = this.files[item.file.index]!;
      const from = item.start * BLOCK_SIZE;
      const to = Math.min(src.size, (item.start + item.count) * BLOCK_SIZE);
      let t = this.now();
      const body = new Uint8Array(await src.blob.slice(from, to).arrayBuffer());
      if (flight.ac.signal.aborted) throw new TransportError("CANCELLED");
      let t2 = this.now();
      st.readMs += t2 - t;
      const digests = hasher.hashBlocks(body, BLOCK_SIZE);
      this.storeHashes(item.file, item.start, digests);
      const hashes = bytesToBase64Url(digests);
      t = this.now();
      st.hashMs += t - t2;
      const { load } = await this.transport.putBlocks(this.id, item.file.id, item.start, body, hashes, flight.ac.signal);
      t2 = this.now();
      st.networkMs += t2 - t;
      this.wireBytes += body.byteLength + hashes.length;
      this.recordSuccess(body.byteLength, t2 - t, load);
      this.planner.ack(item);
      return;
    }

    let t = this.now();
    const buffers = await Promise.all(item.files.map((f) => this.files[f.index]!.blob.arrayBuffer()));
    if (flight.ac.signal.aborted) throw new TransportError("CANCELLED");
    let t2 = this.now();
    st.readMs += t2 - t;
    const entries = item.files.map((f, i) => ({
      id: f.id,
      size: buffers[i]!.byteLength,
      hash: bytesToBase64Url(hasher.hashBlocks(new Uint8Array(buffers[i]!), BLOCK_SIZE)),
    }));
    t = this.now();
    st.hashMs += t - t2;
    const header = encodeBatchHeader({ files: entries });
    const frame = new Blob([header, ...buffers]);
    t2 = this.now();
    st.frameMs += t2 - t;
    const { load } = await this.transport.putBatch(this.id, frame, flight.ac.signal);
    t = this.now();
    st.networkMs += t - t2;
    this.wireBytes += frame.size;
    this.recordSuccess(item.bytes, t - t2, load);
    this.planner.ack(item);
    this.filesDone += item.files.length;
    this.fileMeter.add(item.files.length);
  }

  private recordSuccess(bytes: number, latency: number, load: number) {
    this.bytesDone += bytes;
    this.meter.add(bytes);
    this.sampleBytes += bytes;
    this.sampleLatencySum += latency;
    this.sampleLatencyCount++;
    this.sampleLoad = Math.max(this.sampleLoad, load);
    this.consecutiveServerErrors = 0;
    this.requests++;
    this.latencies.add(latency);
  }

  private storeHashes(f: PlanFile, start: number, digests: Uint8Array) {
    const len = HASH_LENGTH[this.hasher!.algo];
    let store = this.hashes.get(f.index);
    if (!store) {
      store = { digests: new Uint8Array(f.blocks * len), known: new Bitset(f.blocks) };
      this.hashes.set(f.index, store);
    }
    store.digests.set(digests, start * len);
    for (let i = 0; i < digests.length / len; i++) store.known.set(start + i);
  }

  private async completeFile(item: Extract<WorkItem, { kind: "complete" }>) {
    const f = item.file;
    const hasher = this.hasher!;
    const len = HASH_LENGTH[hasher.algo];
    let store = this.hashes.get(f.index);
    if (!store) {
      store = { digests: new Uint8Array(f.blocks * len), known: new Bitset(f.blocks) };
      this.hashes.set(f.index, store);
    }
    // Blocks sent in an earlier session: hash them locally so the root covers the whole file.
    if (!store.known.complete) {
      const src = this.files[f.index]!;
      for (const [a, b] of store.known.missingRuns()) {
        for (let i = a; i < b; i += 16) {
          const end = Math.min(b, i + 16);
          const buf = new Uint8Array(await src.blob.slice(i * BLOCK_SIZE, Math.min(src.size, end * BLOCK_SIZE)).arrayBuffer());
          this.storeHashes(f, i, hasher.hashBlocks(buf, BLOCK_SIZE));
        }
      }
    }
    try {
      const { finalName } = await this.transport.complete(this.id, f.id, hasher.root(store.digests));
      f.finalName = finalName;
      this.planner.ack(item);
      this.filesDone++;
      this.fileMeter.add(1);
      this.hashes.delete(f.index);
    } catch (err) {
      if (err instanceof TransportError && err.code === "INTEGRITY") {
        // The receiver's copy doesn't match this file (it changed since an earlier session,
        // or a block went bad on disk). The receiver discarded it; start this file over.
        this.bytesDone -= this.planner.ackedBytes(f);
        this.chunkFailures++;
        this.hashes.delete(f.index);
        this.planner.resetFile(f);
        if (++f.strikes >= MAX_STRIKES) f.state = "failed";
        return;
      }
      throw err;
    }
  }

  private onFlightError(flight: Flight, err: unknown) {
    const { item } = flight;
    // A failed completion leaves the last block un-acked; release makes it resendable.
    this.planner.release(item);
    if (flight.intentional) return;

    const code: ErrorCode = err instanceof TransportError ? err.code : "SERVER";
    if (code === "CANCELLED") return;
    this.retries++;
    this.sampleErrors++;
    this.recentErrors.push(this.now());

    switch (code) {
      case "NETWORK":
        void this.reconnect(true);
        return;
      case "INCOMPLETE":
        // Receiver lost track of some blocks (e.g. it restarted): resync and fill the gaps.
        void this.reconnect(false);
        return;
      case "INTEGRITY":
      case "BAD_FRAME":
        this.chunkFailures++;
        this.strike(item);
        return;
      case "UNAUTHORIZED":
      case "FORBIDDEN":
      case "NOT_FOUND":
      case "TOO_LARGE":
        this.fail(code);
        return;
      case "DISK_FULL":
      case "DISK_WRITE":
        this.pauseWithError(code);
        return;
      default:
        this.strike(item);
        if (++this.consecutiveServerErrors >= 8) this.pauseWithError(code);
    }
  }

  private strike(item: WorkItem) {
    const files = item.kind === "batch" ? item.files : [item.file];
    for (const f of files) if (++f.strikes >= MAX_STRIKES) f.state = "failed";
  }

  private async reconnect(isDrop: boolean): Promise<void> {
    if (this._state === "reconnecting" || this._state === "cancelled" || this._state === "complete") return;
    if (isDrop) this.reconnects++;
    this.abortAll();
    this.meter.stop();
    this.fileMeter.stop();
    this.stopSampling();
    this.reconnectingSince = this.now();
    this.setState("reconnecting");
    let delay = 400;
    while (this.is("reconnecting")) {
      try {
        await this.waitForDrain();
        await this.transport.ping();
        const status = await this.transport.status(this.id);
        if (!this.is("reconnecting")) return;
        this.adopt(status);
        this.run();
        return;
      } catch (err) {
        if (err instanceof TransportError && (err.code === "NOT_FOUND" || err.code === "UNAUTHORIZED")) {
          this.fail(err.code);
          return;
        }
        await sleep(delay);
        delay = Math.min(delay * 2, 5000);
        this.emit(); // lets the UI refresh the "still trying" message
      }
    }
  }

  private async waitForDrain() {
    while (this.flights.size > 0) await sleep(20);
  }

  private abortAll() {
    for (const f of this.flights) {
      f.intentional = true;
      f.ac.abort();
    }
  }

  private finish() {
    this.stopSampling();
    this.meter.stop();
    this.fileMeter.stop();
    const failed = this.planner.files.some((f) => f.state === "failed");
    if (failed) {
      this.errorCode = "INTEGRITY";
      this.setState("failed");
    } else {
      this.setState("complete");
    }
    this.resolveDone();
  }

  private fail(code: ErrorCode) {
    this.abortAll();
    this.stopSampling();
    this.meter.stop();
    this.errorCode = code;
    this.setState("failed");
    this.resolveDone();
  }

  private pauseWithError(code: ErrorCode) {
    this.errorCode = code;
    this.pause();
  }

  private handleFatal(err: unknown) {
    const code: ErrorCode = err instanceof TransportError ? err.code : "SERVER";
    if (code === "NETWORK") {
      // Couldn't even create the transfer: keep trying like any other drop.
      this._state = "running";
      void this.reconnectFromScratch();
      return;
    }
    this.fail(code);
  }

  private async reconnectFromScratch() {
    this.setState("reconnecting");
    let delay = 500;
    while (this.is("reconnecting")) {
      await sleep(delay);
      delay = Math.min(delay * 2, 5000);
      try {
        const status = await this.negotiate();
        if (!status) return;
        this.adopt(status);
        this.run();
        return;
      } catch (err) {
        if (!(err instanceof TransportError) || err.code !== "NETWORK") return this.fail(err instanceof TransportError ? err.code : "SERVER");
      }
    }
  }

  private startSampling() {
    this.stopSampling();
    this.sampleStart = this.now();
    const every = this.opts.sampleIntervalMs ?? 1000;
    this.sampleTimer = setInterval(() => this.sample(), every);
    (this.sampleTimer as { unref?: () => void }).unref?.();
  }

  private stopSampling() {
    if (this.sampleTimer) clearInterval(this.sampleTimer);
    this.sampleTimer = null;
  }

  private sample() {
    if (this._state !== "running") return;
    const t = this.now();
    const dt = Math.max(1, t - this.sampleStart);
    const before = this.controller.streams;
    const throughput = (this.sampleBytes * 1000) / dt;
    if (throughput > 0) this.tputSamples.add(throughput);
    const decision = this.controller.update({
      throughput,
      avgLatencyMs: this.sampleLatencyCount ? this.sampleLatencySum / this.sampleLatencyCount : 0,
      errors: this.sampleErrors,
      serverLoad: this.sampleLoad,
    });
    this.lastDecision = decision.reason;
    this.sampleStart = t;
    this.sampleBytes = 0;
    this.sampleLatencySum = 0;
    this.sampleLatencyCount = 0;
    this.sampleErrors = 0;
    this.sampleLoad = 0;
    const cutoff = t - 10_000;
    while (this.recentErrors.length && this.recentErrors[0]! < cutoff) this.recentErrors.shift();
    if (decision.streams > before) this.pump();
  }

  private health(speed: number): Health {
    if (this._state === "reconnecting") return "offline";
    const errs = this.recentErrors.length;
    const rtt = this.rtt ?? 0;
    if (errs >= 4 || rtt > 200) return "poor";
    if (errs >= 1 || rtt > 60) return "fair";
    if (this._state === "running" && speed > 0 && speed < 5e6) return "fair";
    if (rtt > 15) return "good";
    return "excellent";
  }

  private message(): string | null {
    if (this._state === "reconnecting") {
      return this.now() - this.reconnectingSince > STALL_MESSAGE_AFTER_MS
        ? "Transfer paused because the other device is unavailable. It will continue when it's back."
        : userMessageFor("NETWORK");
    }
    if (this.errorCode) {
      if (this._state === "failed" && this.errorCode === "INTEGRITY") {
        const n = this.planner.files.filter((f) => f.state === "failed").length;
        return `${n} ${n === 1 ? "file" : "files"} kept arriving damaged. Retry them, or check the Wi-Fi.`;
      }
      return userMessageFor(this.errorCode);
    }
    return null;
  }

  /** Unnarrowed state check: the state changes across awaits, TS can't see that. */
  private is(s: JobState): boolean {
    return this._state === s;
  }

  private setState(s: JobState) {
    if (this._state === s) return;
    this._state = s;
    this.emit();
  }

  private emit() {
    for (const fn of this.listeners) fn(this);
  }
}

function itemBytes(item: WorkItem, files: SourceFile[]): number {
  if (item.kind === "batch") return item.bytes;
  if (item.kind === "complete") return 0;
  const size = files[item.file.index]!.size;
  return Math.min(size, (item.start + item.count) * BLOCK_SIZE) - item.start * BLOCK_SIZE;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
