import type { CreateTransfer } from "@swiftdrop/protocol";

/**
 * Data plane between two phones: one reliable, ordered RTCDataChannel. Nothing here knows
 * about signaling; the channel arrives already open (or opening).
 *
 * Wire format v2. The message type alone tells control from data, so file bytes need no
 * header and go out as views of the buffer they were read into (no per-frame copy):
 *
 *   string message   control: compact JSON (requests, responses, aborts)
 *   binary message   body bytes of the request currently streaming
 *
 * Bodies are sent one request at a time, each right after its own `req` message, so the
 * receiver attributes binary messages to requests by order alone. A request aborted
 * mid-body is closed by `{t:"abort", id, sent}` in the same ordered stream: the receiver
 * drops what arrived of it and moves on.
 */

export type ControlMessage =
  | { t: "req"; id: number; op: string; args?: unknown; len?: number }
  | { t: "res"; id: number; ok: true; result?: unknown }
  | { t: "res"; id: number; ok: false; code: string }
  | { t: "abort"; id: number; sent?: number };

/** What PeerTransport and PeerReceiver need from a link. WebRTC is one implementation. */
export interface PhoneTransport {
  /** Resolves once the link can carry frames. */
  connect(): Promise<void>;
  /** The manifest is a control request like any other; named because it opens a transfer. */
  sendManifest(reqId: number, manifest: CreateTransfer): Promise<void>;
  /**
   * A request with a body: its `req` message, then the body, with no other body in
   * between. Waits while the send buffer is over its high-water mark. Stops early (and
   * tells the receiver) when `signal` aborts.
   */
  sendRequest(req: Extract<ControlMessage, { t: "req" }>, body: Uint8Array, signal?: AbortSignal): Promise<void>;
  sendControl(msg: ControlMessage): Promise<void>;
  close(): Promise<void>;
  getBufferedAmount(): number;
  /** Largest body slice one message carries. */
  readonly chunkBytes: number;
  readonly isOpen: boolean;
  onControl(fn: (msg: ControlMessage) => void): void;
  /** Body bytes of request `reqId` at `offset`. The view is only valid during the call. */
  onChunk(fn: (reqId: number, offset: number, bytes: Uint8Array) => void): void;
  onClose(fn: () => void): void;
}

/** The subset of RTCDataChannel this code uses; lets tests supply an in-memory link. */
export interface ChannelLike {
  readonly readyState: "connecting" | "open" | "closing" | "closed";
  readonly bufferedAmount: number;
  bufferedAmountLowThreshold: number;
  binaryType: string;
  send(data: string | ArrayBuffer | ArrayBufferView<ArrayBuffer>): void;
  close(): void;
  addEventListener(type: "open" | "close" | "error" | "bufferedamountlow", fn: () => void): void;
  addEventListener(type: "message", fn: (ev: { data: unknown }) => void): void;
}

export interface FramingOptions {
  /** Upper bound per DataChannel message (the peer's SCTP max-message-size). */
  maxMessageSize?: number;
  /** Pause sending above this many buffered bytes. */
  highWaterMark?: number;
  /** Resume below this (bufferedAmountLowThreshold). */
  lowWaterMark?: number;
}

/** Live counters for the debug panel. Cheap: plain fields, no allocation. */
export interface LinkStats {
  bytesSent: number;
  framesSent: number;
  bytesReceived: number;
  /** ms spent waiting for the send buffer to drain */
  stallMs: number;
  stalls: number;
  peakBuffered: number;
}

/**
 * Measured on two separate Chromium processes (tests/performance/raw-datachannel.ts):
 * 64 KiB messages with a 4–16 MiB send buffer beat 16 KiB and 256 KiB messages, and beat a
 * 1 MiB buffer by ~25%. 64 KiB is also the largest size every Safari/Chrome pair accepts.
 */
export const DEFAULT_FRAME = 64 * 1024;
export const DEFAULT_HIGH_WATER = 8 << 20;
const MAX_MESSAGE = 256 * 1024;
const MIN_MESSAGE = 16 * 1024;

type Req = Extract<ControlMessage, { t: "req" }>;

export class DataChannelTransport implements PhoneTransport {
  readonly chunkBytes: number;
  private readonly high: number;
  private readonly controlFns: Array<(m: ControlMessage) => void> = [];
  private readonly chunkFns: Array<(id: number, off: number, b: Uint8Array) => void> = [];
  private readonly closeFns: Array<() => void> = [];
  private drainWaiters: Array<() => void> = [];
  private closed = false;
  /** Bodies go out one at a time: each waits for the previous one. */
  private bodyLock: Promise<void> = Promise.resolve();
  /** Receive side: requests whose bodies are still due, in arrival order. */
  private readonly due: Array<{ id: number; len: number; got: number }> = [];
  readonly stats: LinkStats = { bytesSent: 0, framesSent: 0, bytesReceived: 0, stallMs: 0, stalls: 0, peakBuffered: 0 };

  constructor(
    private readonly ch: ChannelLike,
    opts: FramingOptions = {},
  ) {
    const max = Math.max(MIN_MESSAGE, Math.min(MAX_MESSAGE, opts.maxMessageSize || DEFAULT_FRAME));
    this.chunkBytes = max;
    this.high = opts.highWaterMark ?? DEFAULT_HIGH_WATER;
    ch.binaryType = "arraybuffer";
    ch.bufferedAmountLowThreshold = opts.lowWaterMark ?? this.high / 4;
    ch.addEventListener("bufferedamountlow", () => this.wake());
    ch.addEventListener("close", () => this.shutdown());
    ch.addEventListener("error", () => this.shutdown());
    ch.addEventListener("message", (ev) => this.receive(ev.data));
  }

  /** Back-compat for tests and the bench: bytes actually handed to the channel. */
  get bytesSent(): number {
    return this.stats.bytesSent;
  }
  get peakBuffered(): number {
    return this.stats.peakBuffered;
  }

  get isOpen(): boolean {
    return !this.closed && this.ch.readyState === "open";
  }

  connect(): Promise<void> {
    if (this.ch.readyState === "open") return Promise.resolve();
    if (this.closed || this.ch.readyState !== "connecting") return Promise.reject(new Error("channel closed"));
    return new Promise((resolve, reject) => {
      this.ch.addEventListener("open", () => resolve());
      this.closeFns.push(() => reject(new Error("channel closed")));
    });
  }

  sendManifest(reqId: number, manifest: CreateTransfer): Promise<void> {
    return this.sendControl({ t: "req", id: reqId, op: "create", args: manifest });
  }

  async sendControl(msg: ControlMessage): Promise<void> {
    // Control skips the high-water wait: acks and aborts must never queue behind data.
    this.push(JSON.stringify(msg), 0);
  }

  sendRequest(req: Req, body: Uint8Array, signal?: AbortSignal): Promise<void> {
    const run = this.bodyLock.then(() => this.streamBody(req, body, signal));
    // The next body waits for this one whatever happens to it.
    this.bodyLock = run.catch(() => undefined);
    return run;
  }

  async close(): Promise<void> {
    this.ch.close();
    this.shutdown();
  }

  getBufferedAmount(): number {
    return this.ch.bufferedAmount;
  }

  onControl(fn: (msg: ControlMessage) => void) {
    this.controlFns.push(fn);
  }
  onChunk(fn: (reqId: number, offset: number, bytes: Uint8Array) => void) {
    this.chunkFns.push(fn);
  }
  onClose(fn: () => void) {
    if (this.closed) queueMicrotask(fn);
    else this.closeFns.push(fn);
  }

  // ---------------------------------------------------------------------------

  private async streamBody(req: Req, body: Uint8Array, signal?: AbortSignal) {
    if (signal?.aborted) return;
    const len = body.byteLength;
    this.push(JSON.stringify({ ...req, len }), 0);
    const step = this.chunkBytes;
    for (let at = 0; at < len; at += step) {
      const end = Math.min(len, at + step);
      while (this.ch.bufferedAmount + (end - at) > this.high && this.ch.bufferedAmount > 0) {
        const t0 = performance.now();
        await this.drained();
        this.stats.stallMs += performance.now() - t0;
        this.stats.stalls++;
      }
      if (signal?.aborted) {
        this.push(JSON.stringify({ t: "abort", id: req.id, sent: at } satisfies ControlMessage), 0);
        return;
      }
      // A view, not a copy: send() copies into the SCTP queue itself.
      this.push(body.subarray(at, end) as Uint8Array<ArrayBuffer>, end - at);
    }
  }

  private push(data: string | Uint8Array<ArrayBuffer>, payload: number) {
    if (!this.isOpen) throw new ChannelClosedError();
    try {
      this.ch.send(data);
    } catch {
      // Chrome throws when its send queue overflows; Safari when the channel just died.
      this.shutdown();
      throw new ChannelClosedError();
    }
    const s = this.stats;
    s.framesSent++;
    s.bytesSent += payload || (data as string).length;
    const b = this.ch.bufferedAmount;
    if (b > s.peakBuffered) s.peakBuffered = b;
  }

  private async drained() {
    if (!this.isOpen) throw new ChannelClosedError();
    // The event is the fast path; the timer covers engines that skip it when the
    // threshold is crossed inside one drain.
    await new Promise<void>((resolve) => {
      const t = setTimeout(done, 50);
      this.drainWaiters.push(done);
      function done() {
        clearTimeout(t);
        resolve();
      }
    });
    if (!this.isOpen) throw new ChannelClosedError();
  }

  private wake() {
    const w = this.drainWaiters;
    this.drainWaiters = [];
    for (const fn of w) fn();
  }

  private receive(data: unknown) {
    if (typeof data === "string") {
      let msg: ControlMessage;
      try {
        msg = JSON.parse(data) as ControlMessage;
      } catch {
        return;
      }
      if (msg.t === "req" && msg.len && msg.len > 0) this.due.push({ id: msg.id, len: msg.len, got: 0 });
      else if (msg.t === "abort") {
        const i = this.due.findIndex((d) => d.id === msg.id);
        if (i >= 0) this.due.splice(i, 1);
      }
      for (const fn of this.controlFns) fn(msg);
      return;
    }
    if (!(data instanceof ArrayBuffer) || data.byteLength === 0) return;
    this.stats.bytesReceived += data.byteLength;
    let bytes = new Uint8Array(data);
    // Normally one message belongs to one request; split defensively if a peer packed two.
    while (bytes.byteLength) {
      const cur = this.due[0];
      if (!cur) return; // stray bytes: nothing is expecting a body
      const take = Math.min(bytes.byteLength, cur.len - cur.got);
      const part = take === bytes.byteLength ? bytes : bytes.subarray(0, take);
      for (const fn of this.chunkFns) fn(cur.id, cur.got, part);
      cur.got += take;
      if (cur.got >= cur.len) this.due.shift();
      bytes = bytes.subarray(take);
    }
  }

  private shutdown() {
    if (this.closed) return;
    this.closed = true;
    this.due.length = 0;
    this.wake();
    const fns = this.closeFns.splice(0);
    for (const fn of fns) fn();
  }
}

export class ChannelClosedError extends Error {
  constructor() {
    super("channel closed");
  }
}
