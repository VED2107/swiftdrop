import type { CreateTransfer, ErrorCode, TransferStatus } from "@swiftdrop/protocol";
import { ERROR_CODES } from "@swiftdrop/protocol";
import { TransportError, type CreateResult, type Transport } from "@swiftdrop/transfer-engine";
import type { ControlMessage, PhoneTransport } from "./channel.ts";

/**
 * The engine's `Transport` over a phone-to-phone link. Every engine call becomes one RPC:
 * a control request, then (for data) the body as frames on the same ordered channel, then
 * the receiver's response. The engine's parallel "streams" become pipelined requests.
 *
 * The link can be swapped (`attach`) after a drop and re-pairing; pending calls fail with
 * NETWORK, the engine's reconnect loop pings until a new link is attached, asks for the
 * receiver's status and sends only what's missing.
 */
export class PeerTransport implements Transport {
  private link: PhoneTransport | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();

  constructor(link?: PhoneTransport) {
    if (link) this.attach(link);
  }

  get connected(): boolean {
    return Boolean(this.link?.isOpen);
  }

  attach(link: PhoneTransport) {
    this.link = link;
    link.onControl((m) => this.onControl(m));
    link.onClose(() => {
      if (this.link !== link) return;
      this.link = null;
      this.failAll();
    });
  }

  create(req: CreateTransfer): Promise<CreateResult> {
    // No timeout: this waits for a person on the other phone to tap Accept.
    return this.call<CreateResult>("create", req);
  }

  status(transferId: string): Promise<TransferStatus> {
    return this.call<TransferStatus>("status", { transferId }, undefined, undefined, 15_000);
  }

  async putBlocks(transferId: string, fileId: string, startBlock: number, body: Uint8Array<ArrayBuffer>, hashes: string, signal: AbortSignal) {
    return this.call<{ load: number }>("blocks", { transferId, fileId, start: startBlock, hashes }, body, signal);
  }

  async putBatch(transferId: string, body: Blob, signal: AbortSignal) {
    const bytes = new Uint8Array(await body.arrayBuffer());
    return this.call<{ load: number }>("batch", { transferId }, bytes, signal);
  }

  complete(transferId: string, fileId: string, root: string) {
    return this.call<{ finalName: string }>("complete", { transferId, fileId, root });
  }

  async cancel(transferId: string): Promise<void> {
    await this.call("cancel", { transferId }, undefined, undefined, 5000);
  }

  async ping(signal?: AbortSignal): Promise<void> {
    await this.call("ping", {}, undefined, signal, 5000);
  }

  // ---------------------------------------------------------------------------

  private async call<T>(op: string, args: unknown, body?: Uint8Array, signal?: AbortSignal, timeoutMs?: number): Promise<T> {
    const link = this.link;
    if (!link?.isOpen) throw new TransportError("NETWORK", 0, "not connected");
    if (signal?.aborted) throw new TransportError("CANCELLED");
    const id = this.nextId++;
    const result = new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
    });
    let timer: ReturnType<typeof setTimeout> | undefined;
    const onAbort = () => {
      void link.sendControl({ t: "abort", id }).catch(() => undefined);
      this.settle(id, new TransportError("CANCELLED"));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    if (timeoutMs) timer = setTimeout(() => this.settle(id, new TransportError("NETWORK", 0, `${op} timed out`)), timeoutMs);
    try {
      const req: ControlMessage = { t: "req", id, op, args };
      if (body) req.len = body.byteLength;
      if (op === "create") await link.sendManifest(id, args as CreateTransfer);
      else await link.sendControl(req);
      if (body && body.byteLength) await link.sendChunk(id, 0, body);
    } catch {
      this.settle(id, new TransportError("NETWORK", 0, "link closed while sending"));
    }
    try {
      return await result;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    }
  }

  private onControl(m: ControlMessage) {
    if (m.t !== "res") return;
    const p = this.pending.get(m.id);
    if (!p) return;
    this.pending.delete(m.id);
    if (m.ok) p.resolve(m.result);
    else p.reject(new TransportError(asCode(m.code), 0));
  }

  private settle(id: number, err: Error) {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    p.reject(err);
  }

  private failAll() {
    for (const id of [...this.pending.keys()]) this.settle(id, new TransportError("NETWORK", 0, "link closed"));
  }
}

function asCode(code: string): ErrorCode {
  return (ERROR_CODES as readonly string[]).includes(code) ? (code as ErrorCode) : "SERVER";
}
