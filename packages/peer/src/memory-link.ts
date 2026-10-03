import type { ChannelLike } from "./channel.ts";

/**
 * Two connected in-memory channels that behave like RTCDataChannel where it matters:
 * `bufferedAmount` grows on send and drains at a fixed rate, `bufferedamountlow` fires
 * when it crosses the threshold, delivery is ordered and asynchronous, and either side can
 * be cut. Used by tests to run the real framing, backpressure and RPC code without WebRTC.
 */
export interface MemoryLinkOptions {
  /** bytes per millisecond the "network" drains (default 200 = 200 MB/s) */
  rate?: number;
  /** throw from send() above this many buffered bytes (Chrome closes the channel) */
  sendQueueLimit?: number;
  /** tamper with a binary frame in flight; return the bytes to deliver */
  tamper?: (frame: Uint8Array) => Uint8Array;
}

type Listener = (ev: { data: unknown }) => void;

class MemoryChannel implements ChannelLike {
  readyState: ChannelLike["readyState"] = "connecting";
  bufferedAmount = 0;
  bufferedAmountLowThreshold = 0;
  binaryType = "arraybuffer";
  peer!: MemoryChannel;
  private readonly listeners = new Map<string, Array<(ev: { data: unknown }) => void>>();
  private queue: Array<Uint8Array | string> = [];
  private draining = false;

  constructor(private readonly opts: MemoryLinkOptions) {}

  addEventListener(type: string, fn: Listener | (() => void)) {
    const list = this.listeners.get(type) ?? [];
    list.push(fn as Listener);
    this.listeners.set(type, list);
  }

  emit(type: string, data?: unknown) {
    for (const fn of this.listeners.get(type) ?? []) fn({ data });
  }

  send(data: string | ArrayBuffer | ArrayBufferView<ArrayBuffer>) {
    if (this.readyState !== "open") throw new Error("InvalidStateError");
    // Copied like the real thing: the caller may reuse its buffer right after send().
    const item =
      typeof data === "string" ? data : data instanceof ArrayBuffer ? new Uint8Array(data.slice(0)) : new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
    const size = typeof item === "string" ? item.length : item.byteLength;
    if (this.bufferedAmount + size > (this.opts.sendQueueLimit ?? 16 << 20)) throw new Error("OperationError: send queue is full");
    this.bufferedAmount += size;
    this.queue.push(item);
    if (!this.draining) this.drain();
  }

  private drain() {
    this.draining = true;
    const rate = this.opts.rate ?? 200;
    const step = () => {
      if (this.readyState !== "open") {
        this.draining = false;
        return;
      }
      let budget = rate * 2;
      while (this.queue.length && budget > 0) {
        const f = this.queue.shift()!;
        const size = typeof f === "string" ? f.length : f.byteLength;
        budget -= size;
        const before = this.bufferedAmount;
        this.bufferedAmount -= size;
        let msg: string | ArrayBuffer;
        if (typeof f === "string") msg = f;
        else {
          const out = this.opts.tamper ? this.opts.tamper(f) : f;
          msg = out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength) as ArrayBuffer;
        }
        queueMicrotask(() => this.peer.readyState === "open" && this.peer.emit("message", msg));
        if (before > this.bufferedAmountLowThreshold && this.bufferedAmount <= this.bufferedAmountLowThreshold) this.emit("bufferedamountlow");
      }
      if (this.queue.length) setTimeout(step, 2);
      else this.draining = false;
    };
    setTimeout(step, 0);
  }

  close() {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    this.queue = [];
    this.bufferedAmount = 0;
    this.emit("close");
    if (this.peer.readyState !== "closed") this.peer.close();
  }

  open() {
    this.readyState = "open";
    this.emit("open");
  }
}

export function memoryLink(opts: MemoryLinkOptions = {}): [ChannelLike & { close(): void }, ChannelLike & { close(): void }] {
  const a = new MemoryChannel(opts);
  const b = new MemoryChannel({ ...opts, tamper: undefined });
  a.peer = b;
  b.peer = a;
  setTimeout(() => {
    a.open();
    b.open();
  }, 0);
  return [a, b];
}
