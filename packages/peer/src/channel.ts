import type { CreateTransfer } from "@swiftdrop/protocol";

/**
 * Data plane between two phones: one reliable, ordered RTCDataChannel carrying binary
 * frames. Nothing here knows about signaling; the channel arrives already open (or opening).
 *
 *   0x01 | UTF-8 JSON                       control (requests, responses, aborts)
 *   0x02 | u32 reqId | u32 offset | bytes   body bytes of request `reqId`, at `offset`
 */

export type ControlMessage =
  | { t: "req"; id: number; op: string; args?: unknown; len?: number }
  | { t: "res"; id: number; ok: true; result?: unknown }
  | { t: "res"; id: number; ok: false; code: string }
  | { t: "abort"; id: number };

/** What PeerTransport and PeerReceiver need from a link. WebRTC is one implementation. */
export interface PhoneTransport {
  /** Resolves once the link can carry frames. */
  connect(): Promise<void>;
  /** The manifest is a control request like any other; named because it opens a transfer. */
  sendManifest(reqId: number, manifest: CreateTransfer): Promise<void>;
  /** Body bytes of a request. Waits while the send buffer is over its high-water mark. */
  sendChunk(reqId: number, offset: number, bytes: Uint8Array): Promise<void>;
  sendControl(msg: ControlMessage): Promise<void>;
  close(): Promise<void>;
  getBufferedAmount(): number;
  /** Largest body slice one frame carries. */
  readonly chunkBytes: number;
  readonly isOpen: boolean;
  onControl(fn: (msg: ControlMessage) => void): void;
  onChunk(fn: (reqId: number, offset: number, bytes: Uint8Array) => void): void;
  onClose(fn: () => void): void;
}

/** The subset of RTCDataChannel this code uses; lets tests supply an in-memory link. */
export interface ChannelLike {
  readonly readyState: "connecting" | "open" | "closing" | "closed";
  readonly bufferedAmount: number;
  bufferedAmountLowThreshold: number;
  binaryType: string;
  send(data: ArrayBuffer | ArrayBufferView<ArrayBuffer>): void;
  close(): void;
  addEventListener(type: "open" | "close" | "error" | "bufferedamountlow", fn: () => void): void;
  addEventListener(type: "message", fn: (ev: { data: unknown }) => void): void;
}

export interface FramingOptions {
  /** Upper bound per DataChannel message (the peer's SCTP max-message-size, capped at 64 KiB). */
  maxMessageSize?: number;
  /** Pause sending above this many buffered bytes. */
  highWaterMark?: number;
  /** Resume below this (bufferedAmountLowThreshold). */
  lowWaterMark?: number;
}

const CONTROL = 1;
const DATA = 2;
const DATA_HEADER = 9;
const DEFAULT_MAX_MESSAGE = 64 * 1024;
const MIN_MESSAGE = 16 * 1024;

export class DataChannelTransport implements PhoneTransport {
  readonly chunkBytes: number;
  private readonly high: number;
  private readonly controlFns: Array<(m: ControlMessage) => void> = [];
  private readonly chunkFns: Array<(id: number, off: number, b: Uint8Array) => void> = [];
  private readonly closeFns: Array<() => void> = [];
  private drainWaiters: Array<() => void> = [];
  private closed = false;
  private readonly encoder = new TextEncoder();
  private readonly decoder = new TextDecoder();
  /** Highest bufferedAmount seen right after a send: proves backpressure holds. */
  peakBuffered = 0;
  framesSent = 0;
  bytesSent = 0;

  constructor(
    private readonly ch: ChannelLike,
    opts: FramingOptions = {},
  ) {
    const max = Math.max(MIN_MESSAGE, Math.min(DEFAULT_MAX_MESSAGE, opts.maxMessageSize || DEFAULT_MAX_MESSAGE));
    this.chunkBytes = max - DATA_HEADER;
    this.high = opts.highWaterMark ?? 1 << 20;
    ch.binaryType = "arraybuffer";
    ch.bufferedAmountLowThreshold = opts.lowWaterMark ?? 256 * 1024;
    ch.addEventListener("bufferedamountlow", () => this.wake());
    ch.addEventListener("close", () => this.shutdown());
    ch.addEventListener("error", () => this.shutdown());
    ch.addEventListener("message", (ev) => this.receive(ev.data));
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
    const json = this.encoder.encode(JSON.stringify(msg));
    const frame = new Uint8Array(1 + json.byteLength);
    frame[0] = CONTROL;
    frame.set(json, 1);
    // Control frames skip the high-water wait: acks and aborts must never queue behind data.
    this.push(frame);
  }

  async sendChunk(reqId: number, offset: number, bytes: Uint8Array): Promise<void> {
    for (let at = 0; at < bytes.byteLength; at += this.chunkBytes) {
      const size = DATA_HEADER + Math.min(this.chunkBytes, bytes.byteLength - at);
      // Check and send with no await in between: pipelined requests share the buffer, and
      // waking together must not let each of them push a frame over the mark.
      while (this.ch.bufferedAmount + size > this.high && this.ch.bufferedAmount > 0) await this.drained();
      const part = bytes.subarray(at, Math.min(bytes.byteLength, at + this.chunkBytes));
      const frame = new Uint8Array(DATA_HEADER + part.byteLength);
      const view = new DataView(frame.buffer);
      frame[0] = DATA;
      view.setUint32(1, reqId);
      view.setUint32(5, offset + at);
      frame.set(part, DATA_HEADER);
      this.push(frame);
    }
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

  private push(frame: Uint8Array<ArrayBuffer>) {
    if (!this.isOpen) throw new ChannelClosedError();
    try {
      this.ch.send(frame);
    } catch {
      // Chrome throws when its send queue overflows; Safari when the channel just died.
      this.shutdown();
      throw new ChannelClosedError();
    }
    this.framesSent++;
    this.bytesSent += frame.byteLength;
    const b = this.ch.bufferedAmount;
    if (b > this.peakBuffered) this.peakBuffered = b;
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
    if (!(data instanceof ArrayBuffer) || data.byteLength < 1) return;
    const bytes = new Uint8Array(data);
    if (bytes[0] === CONTROL) {
      let msg: ControlMessage;
      try {
        msg = JSON.parse(this.decoder.decode(bytes.subarray(1))) as ControlMessage;
      } catch {
        return;
      }
      for (const fn of this.controlFns) fn(msg);
    } else if (bytes[0] === DATA && bytes.byteLength >= DATA_HEADER) {
      const view = new DataView(data);
      const id = view.getUint32(1);
      const off = view.getUint32(5);
      const body = bytes.subarray(DATA_HEADER);
      for (const fn of this.chunkFns) fn(id, off, body);
    }
  }

  private shutdown() {
    if (this.closed) return;
    this.closed = true;
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
