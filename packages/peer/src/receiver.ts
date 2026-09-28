import { base64UrlToBytes, bytesToBase64Url, createBlockHasher, HASH_LENGTH, type BlockHasher, type HashAlgo } from "@swiftdrop/crypto";
import {
  BATCH_TARGET_BYTES,
  BLOCK_SIZE,
  CreateTransferSchema,
  MAX_BLOCKS_PER_CHUNK,
  ProtocolError,
  decodeBatch,
  type FileState,
  type TransferStatus,
} from "@swiftdrop/protocol";
import { Bitset, sanitizeFileName, sanitizeRelativeDir } from "@swiftdrop/shared";
import type { z } from "zod";
import type { ControlMessage, PhoneTransport } from "./channel.ts";

/**
 * The receiving phone. Same rules as the PC's receiver (apps/server/src/store.ts): every
 * block's digest is checked before it counts, batch frames are verified whole, a file is
 * only complete when the sender's root digest matches ours, and received-block bitmaps
 * make any drop resumable. Only storage differs: bytes go to a `FileSink` (OPFS on a
 * phone), written at their offset as each request arrives, never gathered per file.
 */

type Manifest = z.output<typeof CreateTransferSchema>;

/** Where one file's bytes go. Positional writes; may be called concurrently for different ranges. */
export interface FileSink {
  write(position: number, bytes: Uint8Array): Promise<void>;
  /** Flush and release; the file must be readable afterwards. */
  close(): Promise<void>;
}

export interface SinkFactory {
  open(transferId: string, fileId: string, size: number): Promise<FileSink>;
  /** Discard one file's bytes (root mismatch: start it over). */
  discard(transferId: string, fileId: string): Promise<void>;
  /** Drop everything of a transfer. */
  remove(transferId: string): Promise<void>;
  /** The finished file, disk-backed where the platform allows. */
  file(transferId: string, fileId: string, name: string, type: string): Promise<File>;
}

/** Resume state survives page reloads when a store is given. */
export interface StateStore {
  load(transferId: string): Promise<string | null>;
  save(transferId: string, json: string): Promise<void>;
  remove(transferId: string): Promise<void>;
}

export interface IncomingOffer {
  transferId: string;
  label: string;
  files: Array<{ id: string; name: string; relDir: string; size: number; type: string }>;
  totalBytes: number;
}

export interface ReceivedFile {
  id: string;
  name: string;
  relDir: string[];
  size: number;
  type: string;
  lastModified: number;
  state: FileState;
  received: Bitset;
  digests: Uint8Array | null;
}

export interface ReceivedTransfer {
  id: string;
  label: string;
  integrity: HashAlgo;
  createdAt: number;
  files: ReceivedFile[];
  byId: Map<string, ReceivedFile>;
  bytesTotal: number;
  bytesDone: number;
  filesDone: number;
}

export interface ReceiverOptions {
  sinks: SinkFactory;
  state?: StateStore;
  /** A person decides. Resolve false to decline. Called once per new transfer. */
  accept(offer: IncomingOffer): Promise<boolean>;
  maxFileSize?: number;
  onProgress?(t: ReceivedTransfer): void;
  onComplete?(t: ReceivedTransfer): void;
}

const MAX_BODY = Math.max(MAX_BLOCKS_PER_CHUNK * BLOCK_SIZE, BATCH_TARGET_BYTES) + (2 << 20);
/** Bodies being reassembled across all pipelined requests. The sender's budget is far below. */
const MAX_REASSEMBLY = 96 << 20;

export class PeerReceiver {
  private readonly transfers = new Map<string, ReceivedTransfer>();
  private readonly sinks = new Map<string, Promise<FileSink>>();
  private readonly hashers = new Map<HashAlgo, Promise<BlockHasher>>();
  private readonly persistTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private readonly deciding = new Map<string, Promise<boolean>>();

  constructor(private readonly opts: ReceiverOptions) {}

  /** Serve one link. Several links over time (re-pairing) share this receiver's state. */
  attach(link: PhoneTransport) {
    const bodies = new Map<number, { req: Extract<ControlMessage, { t: "req" }>; buf: Uint8Array; got: number }>();
    const aborted = new Set<number>();
    let reassembling = 0;
    const release = (id: number) => {
      const b = bodies.get(id);
      if (b) reassembling -= b.buf.byteLength;
      bodies.delete(id);
    };
    const respond = (id: number, work: () => Promise<unknown>) => {
      work().then(
        (result) => {
          if (!aborted.has(id)) void link.sendControl({ t: "res", id, ok: true, result }).catch(() => undefined);
        },
        (err: unknown) => {
          const code = err instanceof ProtocolError ? err.code : "SERVER";
          if (!aborted.has(id)) void link.sendControl({ t: "res", id, ok: false, code }).catch(() => undefined);
        },
      );
    };

    link.onControl((m) => {
      if (m.t === "abort") {
        aborted.add(m.id);
        release(m.id);
        return;
      }
      if (m.t !== "req") return;
      const len = m.len ?? 0;
      if (len > 0) {
        if (len > MAX_BODY || reassembling + len > MAX_REASSEMBLY) {
          void link.sendControl({ t: "res", id: m.id, ok: false, code: "TOO_LARGE" }).catch(() => undefined);
          aborted.add(m.id);
          return;
        }
        reassembling += len;
        bodies.set(m.id, { req: m, buf: new Uint8Array(len), got: 0 });
        return;
      }
      respond(m.id, () => this.handle(m.op, m.args, new Uint8Array(0)));
    });

    link.onChunk((id, offset, bytes) => {
      const b = bodies.get(id);
      if (!b) return; // aborted or rejected
      if (offset + bytes.byteLength > b.buf.byteLength) {
        release(id);
        void link.sendControl({ t: "res", id, ok: false, code: "BAD_FRAME" }).catch(() => undefined);
        return;
      }
      b.buf.set(bytes, offset);
      b.got += bytes.byteLength;
      if (b.got < b.buf.byteLength) return;
      const { req, buf } = b;
      release(id);
      respond(id, () => this.handle(req.op, req.args, buf));
    });
  }

  get(transferId: string): ReceivedTransfer | undefined {
    return this.transfers.get(transferId);
  }

  list(): ReceivedTransfer[] {
    return [...this.transfers.values()];
  }

  async file(t: ReceivedTransfer, f: ReceivedFile): Promise<File> {
    return this.opts.sinks.file(t.id, f.id, f.name, f.type);
  }

  async forget(transferId: string): Promise<void> {
    const t = this.transfers.get(transferId);
    if (t) for (const f of t.files) await this.closeSink(t, f);
    this.transfers.delete(transferId);
    clearTimeout(this.persistTimers.get(transferId));
    this.persistTimers.delete(transferId);
    await this.opts.sinks.remove(transferId);
    await this.opts.state?.remove(transferId);
  }

  // ---------------------------------------------------------------------------

  private async handle(op: string, args: unknown, body: Uint8Array): Promise<unknown> {
    const a = (args ?? {}) as Record<string, unknown>;
    switch (op) {
      case "ping":
        return {};
      case "create":
        return this.create(CreateTransferSchema.parse(args));
      case "status":
        return this.status(await this.need(a.transferId));
      case "blocks":
        await this.writeBlocks(await this.need(a.transferId), String(a.fileId), Number(a.start), body, String(a.hashes ?? ""));
        return { load: 0 };
      case "batch":
        await this.writeBatch(await this.need(a.transferId), body);
        return { load: 0 };
      case "complete":
        return { finalName: await this.complete(await this.need(a.transferId), String(a.fileId), String(a.root ?? "")) };
      case "cancel": {
        const t = await this.find(String(a.transferId));
        if (t) await this.forget(t.id);
        return {};
      }
      default:
        throw new ProtocolError("BAD_REQUEST", `unknown op ${op}`);
    }
  }

  private async create(input: Manifest): Promise<{ status: TransferStatus }> {
    if (input.direction !== "to-peer") throw new ProtocolError("FORBIDDEN");
    const existing = await this.find(input.transferId);
    if (existing) {
      if (existing.files.length !== input.files.length || input.files.some((f) => existing.byId.get(f.id)?.size !== f.size)) {
        throw new ProtocolError("BAD_REQUEST", "manifest changed");
      }
      return { status: this.status(existing) };
    }
    const max = this.opts.maxFileSize ?? Number.MAX_SAFE_INTEGER;
    if (input.files.some((f) => f.size > max)) throw new ProtocolError("TOO_LARGE");
    const ids = new Set(input.files.map((f) => f.id));
    if (ids.size !== input.files.length) throw new ProtocolError("BAD_REQUEST", "duplicate file id");

    const files: ReceivedFile[] = input.files.map((f) => ({
      id: f.id,
      name: sanitizeFileName(f.name),
      relDir: sanitizeRelativeDir(f.relDir),
      size: f.size,
      type: f.type.slice(0, 255),
      lastModified: f.lastModified,
      state: "new",
      received: new Bitset(Math.ceil(f.size / BLOCK_SIZE)),
      digests: null,
    }));
    const offer: IncomingOffer = {
      transferId: input.transferId,
      label: input.label.slice(0, 200),
      files: files.map((f) => ({ id: f.id, name: f.name, relDir: f.relDir.join("/"), size: f.size, type: f.type })),
      totalBytes: files.reduce((s, f) => s + f.size, 0),
    };
    // A sender retrying create while the person is still deciding must not ask twice.
    let decision = this.deciding.get(input.transferId);
    if (!decision) {
      decision = this.opts.accept(offer);
      this.deciding.set(input.transferId, decision);
    }
    const ok = await decision.finally(() => this.deciding.delete(input.transferId));
    if (!ok) throw new ProtocolError("DECLINED");
    const raced = this.transfers.get(input.transferId);
    if (raced) return { status: this.status(raced) };

    const t: ReceivedTransfer = {
      id: input.transferId,
      label: offer.label,
      integrity: input.integrity,
      createdAt: Date.now(),
      files,
      byId: new Map(files.map((f) => [f.id, f])),
      bytesTotal: offer.totalBytes,
      bytesDone: 0,
      filesDone: 0,
    };
    for (const f of files) {
      if (f.size === 0) {
        // Nothing to send: the sender only completes it. Create it so it can be saved.
        await (await this.sink(t, f)).close();
        this.sinks.delete(key(t, f));
      }
    }
    this.transfers.set(t.id, t);
    await this.persist(t);
    return { status: this.status(t) };
  }

  status(t: ReceivedTransfer): TransferStatus {
    return {
      transferId: t.id,
      blockSize: BLOCK_SIZE,
      integrity: t.integrity,
      files: t.files.map((f) => {
        const out: TransferStatus["files"][number] = { id: f.id, state: f.state };
        if (f.state === "partial") out.received = f.received.toBase64();
        if (f.state === "complete") out.finalName = [...f.relDir, f.name].join("/");
        return out;
      }),
    };
  }

  private async writeBlocks(t: ReceivedTransfer, fileId: string, start: number, body: Uint8Array, hashesB64: string) {
    const f = t.byId.get(fileId);
    if (!f) throw new ProtocolError("NOT_FOUND");
    if (f.state === "complete" || f.state === "skipped") return;
    const blocks = f.received.size;
    if (!Number.isInteger(start) || start < 0 || start >= blocks) throw new ProtocolError("BAD_REQUEST", "block out of range");
    const count = Math.ceil(body.length / BLOCK_SIZE);
    const from = start * BLOCK_SIZE;
    if (count < 1 || count > MAX_BLOCKS_PER_CHUNK) throw new ProtocolError("BAD_REQUEST", "bad block count");
    if (body.length !== Math.min(f.size, (start + count) * BLOCK_SIZE) - from) throw new ProtocolError("BAD_REQUEST", "body length does not match block range");
    const hasher = await this.hasher(t.integrity);
    const len = HASH_LENGTH[t.integrity];
    let claimed: Uint8Array;
    try {
      claimed = base64UrlToBytes(hashesB64);
    } catch {
      throw new ProtocolError("BAD_REQUEST", "bad block hashes");
    }
    if (claimed.length !== count * len) throw new ProtocolError("BAD_REQUEST", "missing block hashes");
    const actual = hasher.hashBlocks(body, BLOCK_SIZE);
    if (!equal(actual, claimed)) throw new ProtocolError("INTEGRITY");
    try {
      await (await this.sink(t, f)).write(from, body);
    } catch (err) {
      throw storageError(err);
    }
    if (!f.digests) f.digests = new Uint8Array(blocks * len);
    f.digests.set(actual, start * len);
    let fresh = 0;
    for (let i = 0; i < count; i++) if (f.received.set(start + i)) fresh++;
    if (f.state === "new") f.state = "partial";
    t.bytesDone += fresh === count ? body.length : Math.round((body.length * fresh) / count);
    this.touch(t);
  }

  private async writeBatch(t: ReceivedTransfer, frame: Uint8Array) {
    const { header, payload } = decodeBatch(frame);
    const hasher = await this.hasher(t.integrity);
    const work: Array<{ f: ReceivedFile; data: Uint8Array }> = [];
    let offset = 0;
    for (const e of header.files) {
      const f = t.byId.get(e.id);
      const data = payload.subarray(offset, offset + e.size);
      offset += e.size;
      if (!f) throw new ProtocolError("NOT_FOUND");
      if (f.size !== e.size) throw new ProtocolError("BAD_REQUEST", "size mismatch");
      if (f.state === "complete" || f.state === "skipped") continue;
      if (bytesToBase64Url(hasher.hashBlocks(data, BLOCK_SIZE)) !== e.hash) throw new ProtocolError("INTEGRITY");
      work.push({ f, data });
    }
    try {
      for (const { f, data } of work) {
        const sink = await this.sink(t, f);
        if (data.length) await sink.write(0, data);
        await this.closeSink(t, f);
      }
    } catch (err) {
      throw storageError(err);
    }
    for (const { f } of work) {
      f.received = full(f.received.size);
      f.state = "complete";
      f.digests = null;
      t.bytesDone += f.size;
      t.filesDone++;
    }
    this.touch(t);
    this.checkDone(t);
  }

  private async complete(t: ReceivedTransfer, fileId: string, root: string): Promise<string> {
    const f = t.byId.get(fileId);
    if (!f) throw new ProtocolError("NOT_FOUND");
    const name = [...f.relDir, f.name].join("/");
    if (f.state === "complete" || f.state === "skipped") return name;
    if (!f.received.complete) throw new ProtocolError("INCOMPLETE");
    const hasher = await this.hasher(t.integrity);
    if (hasher.root(f.digests ?? new Uint8Array(0)) !== root) {
      await this.closeSink(t, f);
      await this.opts.sinks.discard(t.id, f.id);
      t.bytesDone -= f.size;
      f.received = new Bitset(f.received.size);
      f.digests = null;
      f.state = "new";
      this.touch(t);
      throw new ProtocolError("INTEGRITY");
    }
    await this.closeSink(t, f);
    f.state = "complete";
    f.digests = null;
    t.filesDone++;
    this.touch(t);
    this.checkDone(t);
    return name;
  }

  private checkDone(t: ReceivedTransfer) {
    if (t.filesDone < t.files.length) return;
    void this.persist(t);
    this.opts.onComplete?.(t);
  }

  private async need(id: unknown): Promise<ReceivedTransfer> {
    const t = await this.find(String(id));
    if (!t) throw new ProtocolError("NOT_FOUND");
    return t;
  }

  private async find(id: string): Promise<ReceivedTransfer | null> {
    const live = this.transfers.get(id);
    if (live) return live;
    const raw = await this.opts.state?.load(id).catch(() => null);
    if (!raw) return null;
    try {
      const t = revive(JSON.parse(raw) as Persisted);
      this.transfers.set(t.id, t);
      return t;
    } catch {
      return null;
    }
  }

  private sink(t: ReceivedTransfer, f: ReceivedFile): Promise<FileSink> {
    const k = key(t, f);
    let s = this.sinks.get(k);
    if (!s) {
      s = this.opts.sinks.open(t.id, f.id, f.size);
      this.sinks.set(k, s);
      s.catch(() => this.sinks.delete(k));
    }
    return s;
  }

  private async closeSink(t: ReceivedTransfer, f: ReceivedFile) {
    const k = key(t, f);
    const s = this.sinks.get(k);
    if (!s) return;
    this.sinks.delete(k);
    await (await s).close();
  }

  private hasher(algo: HashAlgo): Promise<BlockHasher> {
    let h = this.hashers.get(algo);
    if (!h) {
      h = createBlockHasher(algo);
      this.hashers.set(algo, h);
    }
    return h;
  }

  private touch(t: ReceivedTransfer) {
    this.opts.onProgress?.(t);
    if (!this.opts.state || this.persistTimers.has(t.id)) return;
    this.persistTimers.set(
      t.id,
      setTimeout(() => {
        this.persistTimers.delete(t.id);
        void this.persist(t).catch(() => undefined);
      }, 1000),
    );
  }

  private async persist(t: ReceivedTransfer) {
    if (!this.opts.state || !this.transfers.has(t.id)) return;
    const p: Persisted = {
      v: 1,
      id: t.id,
      label: t.label,
      integrity: t.integrity,
      createdAt: t.createdAt,
      files: t.files.map((f) => ({
        id: f.id,
        name: f.name,
        relDir: f.relDir,
        size: f.size,
        type: f.type,
        lastModified: f.lastModified,
        state: f.state,
        ...(f.state === "partial" ? { received: f.received.toBase64(), ...(f.digests ? { digests: bytesToBase64Url(f.digests) } : {}) } : {}),
      })),
    };
    await this.opts.state.save(t.id, JSON.stringify(p));
  }
}

interface Persisted {
  v: 1;
  id: string;
  label: string;
  integrity: HashAlgo;
  createdAt: number;
  files: Array<{
    id: string;
    name: string;
    relDir: string[];
    size: number;
    type: string;
    lastModified: number;
    state: FileState;
    received?: string;
    digests?: string;
  }>;
}

function revive(p: Persisted): ReceivedTransfer {
  if (p.v !== 1) throw new Error("unknown state version");
  const len = HASH_LENGTH[p.integrity];
  const files: ReceivedFile[] = p.files.map((pf) => {
    const blocks = Math.ceil(pf.size / BLOCK_SIZE);
    let digests: Uint8Array | null = null;
    if (pf.digests) {
      digests = new Uint8Array(blocks * len);
      digests.set(base64UrlToBytes(pf.digests).subarray(0, blocks * len));
    }
    return {
      id: pf.id,
      name: sanitizeFileName(pf.name),
      relDir: pf.relDir.map((s) => sanitizeFileName(s, "folder")),
      size: pf.size,
      type: pf.type,
      lastModified: pf.lastModified,
      state: pf.state,
      received: pf.state === "complete" ? full(blocks) : pf.received ? Bitset.fromBase64(blocks, pf.received) : new Bitset(blocks),
      digests,
    };
  });
  const t: ReceivedTransfer = {
    id: p.id,
    label: p.label,
    integrity: p.integrity,
    createdAt: p.createdAt,
    files,
    byId: new Map(files.map((f) => [f.id, f])),
    bytesTotal: files.reduce((s, f) => s + f.size, 0),
    bytesDone: 0,
    filesDone: files.filter((f) => f.state === "complete").length,
  };
  for (const f of files) {
    if (f.state === "complete") t.bytesDone += f.size;
    else if (f.state === "partial") t.bytesDone += Math.min(f.size, f.received.count * BLOCK_SIZE);
  }
  return t;
}

function key(t: ReceivedTransfer, f: ReceivedFile) {
  return `${t.id}/${f.id}`;
}

function full(n: number): Bitset {
  const b = new Bitset(n);
  for (let i = 0; i < n; i++) b.set(i);
  return b;
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function storageError(err: unknown): ProtocolError {
  if (err instanceof ProtocolError) return err;
  const name = (err as { name?: string })?.name;
  if (name === "QuotaExceededError") return new ProtocolError("DISK_FULL");
  return new ProtocolError("DISK_WRITE", String((err as Error)?.message ?? err));
}

// ---------------------------------------------------------------------------

/** Keeps files in memory. Tests only (and tiny files): a phone uses the OPFS sink. */
export class MemorySinkFactory implements SinkFactory {
  readonly files = new Map<string, Uint8Array>();

  async open(transferId: string, fileId: string, size: number): Promise<FileSink> {
    const k = `${transferId}/${fileId}`;
    let buf = this.files.get(k);
    if (!buf || buf.length !== size) {
      buf = new Uint8Array(size);
      this.files.set(k, buf);
    }
    const target = buf;
    return {
      async write(position, bytes) {
        target.set(bytes, position);
      },
      async close() {},
    };
  }
  async discard(transferId: string, fileId: string) {
    this.files.delete(`${transferId}/${fileId}`);
  }
  async remove(transferId: string) {
    for (const k of [...this.files.keys()]) if (k.startsWith(`${transferId}/`)) this.files.delete(k);
  }
  async file(transferId: string, fileId: string, name: string, type: string) {
    const b = this.files.get(`${transferId}/${fileId}`);
    if (!b) throw new ProtocolError("NOT_FOUND");
    return new File([b as Uint8Array<ArrayBuffer>], name, { type });
  }
}

export class MemoryStateStore implements StateStore {
  readonly data = new Map<string, string>();
  async load(id: string) {
    return this.data.get(id) ?? null;
  }
  async save(id: string, json: string) {
    this.data.set(id, json);
  }
  async remove(id: string) {
    this.data.delete(id);
  }
}
