import { constants as FS, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { mkdir, open, readdir, readFile, rename, rm, rmdir, stat, statfs, writeFile, type FileHandle } from "node:fs/promises";
import { dirname, join, resolve, sep } from "node:path";
import { base64UrlToBytes, bytesToBase64Url, createBlockHasher, HASH_LENGTH, type BlockHasher, type HashAlgo } from "@swiftdrop/crypto";
import {
  BLOCK_SIZE,
  MAX_BLOCKS_PER_CHUNK,
  ProtocolError,
  decodeBatch,
  type Conflict,
  type Direction,
  type FileState,
  type Offer,
  type TransferStatus,
} from "@swiftdrop/protocol";
import { Bitset, numberedName, Reservoir, sanitizeFileName, sanitizeRelativeDir, type Logger } from "@swiftdrop/shared";
import type { z } from "zod";
import type { CreateTransferSchema } from "@swiftdrop/protocol";

/**
 * Receiving side of a transfer, on the PC's disk.
 *
 * Layout for iPhone -> PC (root = chosen destination folder):
 *   <root>/.swiftdrop/<tid>.json          resume state (bitmaps + block digests)
 *   <root>/.swiftdrop/<tid>/<fid>.part    data, written positionally as blocks arrive
 *   <root>/<relDir>/<name>                final file, atomically renamed on completion
 *
 * Layout for PC -> iPhone (root = outbox):
 *   <outbox>/<tid>.json, <outbox>/<tid>/<fid>
 *
 * Nothing a client sends is trusted: names are sanitized, final paths are checked to
 * stay inside the root, sizes/offsets are bounded by the manifest, every block is
 * hashed and compared before its bits are set.
 */

type CreateInput = z.output<typeof CreateTransferSchema>;

interface FileRec {
  id: string;
  name: string;
  relDir: string[];
  size: number;
  type: string;
  lastModified: number;
  blocks: number;
  decision: "auto" | "replace" | "keep-both";
  state: FileState;
  received: Bitset;
  digests: Uint8Array | null;
  finalName?: string;
}

export interface TransferRec {
  id: string;
  direction: Direction;
  label: string;
  integrity: HashAlgo;
  bench: boolean;
  deviceId: string;
  deviceName: string;
  createdAt: number;
  root: string;
  files: FileRec[];
  byId: Map<string, FileRec>;
  bytesTotal: number;
  bytesDone: number;
  filesDone: number;
  cancelled: boolean;
  dirty: boolean;
  /** all files landed; resume state is no longer needed on disk */
  finished?: boolean;
}

interface PersistedFile {
  id: string;
  name: string;
  relDir: string[];
  size: number;
  type: string;
  lastModified: number;
  decision: FileRec["decision"];
  state: FileState;
  received?: string;
  digests?: string;
  finalName?: string;
}

interface Persisted {
  v: 1;
  id: string;
  direction: Direction;
  label: string;
  integrity: HashAlgo;
  deviceId: string;
  deviceName: string;
  createdAt: number;
  root: string;
  files: PersistedFile[];
}

export interface StoreHooks {
  progress(t: TransferRec): void;
  completed(t: TransferRec): void;
}

export interface StoreOptions {
  destination: () => string;
  outboxDir: string;
  maxFileSize: () => number;
  log: Logger;
  hooks: StoreHooks;
}

/** Receiver pipeline counters (cumulative). Readers take deltas. */
export interface PipelineMetrics {
  requests: number;
  bytes: number;
  /** request body arriving from the socket (wire time as the receiver sees it) */
  recvMs: number;
  hashMs: number;
  writeMs: number;
  filesCreated: number;
  queueBytes: number;
  peakQueueBytes: number;
  writeLatencyP50: number;
  writeLatencyP95: number;
}

const STATE_DIR = ".swiftdrop";
const WRITE_PRESSURE_BYTES = 96 << 20;
const MAX_OPEN_HANDLES = 48;

export class TransferStore {
  private readonly transfers = new Map<string, TransferRec>();
  private readonly handles = new Map<string, { fh: Promise<FileHandle>; used: number; busy: number }>();
  private readonly hashers = new Map<HashAlgo, BlockHasher>();
  private readonly persistTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private namingLock: Promise<unknown> = Promise.resolve();
  private pendingWriteBytes = 0;
  private readonly m = { requests: 0, bytes: 0, recvMs: 0, hashMs: 0, writeMs: 0, filesCreated: 0, peakQueueBytes: 0 };
  private readonly writeLatency = new Reservoir(512);

  constructor(private readonly opts: StoreOptions) {}

  /** 0..1 — how far behind the disk is. Sent to senders as a backpressure hint. */
  get load(): number {
    return Math.min(1, this.pendingWriteBytes / WRITE_PRESSURE_BYTES);
  }

  metrics(): PipelineMetrics {
    return {
      ...this.m,
      queueBytes: this.pendingWriteBytes,
      writeLatencyP50: this.writeLatency.percentile(50),
      writeLatencyP95: this.writeLatency.percentile(95),
    };
  }

  /** Time the route spent pulling a body off the socket. */
  noteReceive(bytes: number, ms: number) {
    this.m.requests++;
    this.m.bytes += bytes;
    this.m.recvMs += ms;
  }

  private queue(bytes: number) {
    this.pendingWriteBytes += bytes;
    if (this.pendingWriteBytes > this.m.peakQueueBytes) this.m.peakQueueBytes = this.pendingWriteBytes;
  }

  async create(input: CreateInput, device: { id: string; name: string }): Promise<{ status: TransferStatus } | { conflicts: Conflict[] }> {
    const existing = await this.find(input.transferId);
    if (existing) {
      if (existing.cancelled) throw new ProtocolError("NOT_FOUND");
      this.assertSameManifest(existing, input);
      return { status: this.status(existing) };
    }

    const maxSize = this.opts.maxFileSize();
    for (const f of input.files) if (f.size > maxSize) throw new ProtocolError("TOO_LARGE");
    const ids = new Set<string>();
    for (const f of input.files) {
      if (ids.has(f.id)) throw new ProtocolError("BAD_REQUEST", "duplicate file id");
      ids.add(f.id);
    }

    const root =
      input.direction === "to-host" ? resolve(this.opts.destination()) : resolve(this.opts.outboxDir, input.transferId);
    const bytesTotal = input.files.reduce((s, f) => s + f.size, 0);

    if (!input.bench) {
      await this.ensureDir(root);
      await this.ensureDir(this.partDir({ root, direction: input.direction, id: input.transferId }));
      if (input.direction === "to-host") hideOnWindows(join(root, STATE_DIR));
      await this.assertSpace(root, bytesTotal);
    }

    const files: FileRec[] = input.files.map((f) => ({
      id: f.id,
      name: sanitizeFileName(f.name),
      relDir: sanitizeRelativeDir(f.relDir),
      size: f.size,
      type: f.type.slice(0, 255),
      lastModified: f.lastModified,
      blocks: Math.ceil(f.size / BLOCK_SIZE),
      decision: "auto",
      state: "new",
      received: new Bitset(Math.ceil(f.size / BLOCK_SIZE)),
      digests: null,
    }));

    // Duplicate detection by metadata only: an existing file with the same name.
    if (input.direction === "to-host" && !input.bench) {
      const conflicts: Conflict[] = [];
      await forEachLimit(files, 32, async (f) => {
        const target = this.safeJoin(root, [...f.relDir, f.name]);
        const st = await stat(target).catch(() => null);
        if (!st?.isFile()) return;
        const decision = input.decisions[f.id] ?? (input.onConflict === "ask" ? undefined : input.onConflict);
        if (!decision) conflicts.push({ id: f.id, name: [...f.relDir, f.name].join("/"), size: f.size, existingSize: st.size });
        else if (decision === "skip") f.state = "skipped";
        else f.decision = decision;
      });
      if (conflicts.length) return { conflicts };
    }

    const t: TransferRec = {
      id: input.transferId,
      direction: input.direction,
      label: input.label.slice(0, 200),
      integrity: input.integrity,
      bench: input.bench,
      deviceId: device.id,
      deviceName: device.name,
      createdAt: Date.now(),
      root,
      files,
      byId: new Map(files.map((f) => [f.id, f])),
      bytesTotal,
      bytesDone: 0,
      filesDone: 0,
      cancelled: false,
      dirty: true,
    };
    this.transfers.set(t.id, t);
    await this.persist(t);
    this.opts.log.info(`transfer ${t.id} created: ${files.length} files, ${bytesTotal} bytes from ${device.name}`);
    return { status: this.status(t) };
  }

  async get(transferId: string): Promise<TransferRec> {
    const t = await this.find(transferId);
    if (!t || t.cancelled) throw new ProtocolError("NOT_FOUND");
    return t;
  }

  status(t: TransferRec): TransferStatus {
    return {
      transferId: t.id,
      blockSize: BLOCK_SIZE,
      integrity: t.integrity,
      files: t.files.map((f) => {
        const out: TransferStatus["files"][number] = { id: f.id, state: f.state };
        if (f.state === "partial") out.received = f.received.toBase64();
        if (f.finalName) out.finalName = f.finalName;
        return out;
      }),
    };
  }

  /**
   * Write `count` blocks starting at `start`. `body` is exactly the bytes of those blocks.
   * Verified before anything is marked received.
   */
  async writeBlocks(t: TransferRec, fileId: string, start: number, body: Buffer, hashesB64: string | undefined): Promise<void> {
    const f = t.byId.get(fileId);
    if (!f) throw new ProtocolError("NOT_FOUND");
    if (f.state === "complete" || f.state === "skipped") return; // late duplicate: harmless
    if (!Number.isInteger(start) || start < 0 || start >= f.blocks) throw new ProtocolError("BAD_REQUEST", "block out of range");
    const from = start * BLOCK_SIZE;
    const count = Math.ceil(body.length / BLOCK_SIZE);
    if (count < 1 || count > MAX_BLOCKS_PER_CHUNK) throw new ProtocolError("BAD_REQUEST", "bad block count");
    const expected = Math.min(f.size, (start + count) * BLOCK_SIZE) - from;
    if (body.length !== expected) throw new ProtocolError("BAD_REQUEST", "body length does not match block range");

    const hasher = await this.hasher(t.integrity);
    const len = HASH_LENGTH[t.integrity];
    const claimed = hashesB64 ? safeB64(hashesB64) : null;
    if (!claimed || claimed.length !== count * len) throw new ProtocolError("BAD_REQUEST", "missing block hashes");
    let t0 = performance.now();
    const actual = hasher.hashBlocks(body, BLOCK_SIZE);
    this.m.hashMs += performance.now() - t0;
    if (!Buffer.from(actual).equals(Buffer.from(claimed))) throw new ProtocolError("INTEGRITY");

    if (!t.bench) {
      this.queue(body.length);
      t0 = performance.now();
      const h = await this.handle(t, f);
      h.busy++;
      try {
        const fh = await h.fh;
        let written = 0;
        while (written < body.length) {
          const { bytesWritten } = await fh.write(body, written, body.length - written, from + written);
          written += bytesWritten;
        }
      } catch (err) {
        throw diskError(err);
      } finally {
        h.busy--;
        this.pendingWriteBytes -= body.length;
        const ms = performance.now() - t0;
        this.m.writeMs += ms;
        this.writeLatency.add(ms);
      }
    }

    if (!f.digests) f.digests = new Uint8Array(f.blocks * len);
    f.digests.set(actual, start * len);
    let fresh = 0;
    for (let i = 0; i < count; i++) if (f.received.set(start + i)) fresh++;
    if (f.state === "new") f.state = "partial";
    t.bytesDone += fresh === count ? body.length : Math.round((body.length * fresh) / count);
    this.touch(t);
  }

  /** Many small files in one frame; each is verified and written straight to its final place. */
  async writeBatch(t: TransferRec, frame: Buffer): Promise<void> {
    const { header, payload } = decodeBatch(frame);
    const hasher = await this.hasher(t.integrity);
    // Verify the whole frame before touching disk: a bad frame writes nothing.
    const work: Array<{ f: FileRec; data: Buffer; digest: Uint8Array }> = [];
    let offset = 0;
    const h0 = performance.now();
    for (const entry of header.files) {
      const f = t.byId.get(entry.id);
      const data = payload.subarray(offset, offset + entry.size) as Buffer;
      offset += entry.size;
      if (!f) throw new ProtocolError("NOT_FOUND");
      if (f.size !== entry.size) throw new ProtocolError("BAD_REQUEST", "size mismatch");
      if (f.state === "complete" || f.state === "skipped") continue;
      const digest = hasher.hashBlocks(data, BLOCK_SIZE);
      if (bytesToBase64Url(digest) !== entry.hash) throw new ProtocolError("INTEGRITY");
      work.push({ f, data, digest });
    }
    this.m.hashMs += performance.now() - h0;
    if (!t.bench) {
      const bytes = work.reduce((n, w) => n + w.data.length, 0);
      this.queue(bytes);
      const w0 = performance.now();
      try {
        // File creation latency (NTFS, antivirus) dominates small files: overlap it.
        await forEachLimit(work, 16, async ({ f, data }) => {
          const { fh, path } = await this.createExclusive(t, f);
          try {
            if (data.length) await fh.write(data, 0, data.length, 0);
          } finally {
            await fh.close();
          }
          f.finalName = t.direction === "to-guest" ? f.id : relName(t.root, path);
        });
      } catch (err) {
        throw diskError(err);
      } finally {
        this.pendingWriteBytes -= bytes;
        const ms = performance.now() - w0;
        this.m.writeMs += ms;
        this.writeLatency.add(ms);
        this.m.filesCreated += work.length;
      }
    }
    for (const { f, digest } of work) {
      f.digests = digest;
      for (let i = 0; i < f.blocks; i++) f.received.set(i);
      f.state = "complete";
      t.bytesDone += f.size;
      t.filesDone++;
    }
    this.touch(t);
    await this.checkDone(t);
  }

  /**
   * Opens the final file for a small upload. O_EXCL makes name reservation atomic, so
   * parallel writers never collide and no directory-wide lock or pre-stat is needed.
   */
  private async createExclusive(t: TransferRec, f: FileRec): Promise<{ fh: FileHandle; path: string }> {
    if (t.direction === "to-guest") {
      const path = join(t.root, f.id);
      return { fh: await open(path, "w"), path };
    }
    await this.ensureDir(this.safeJoin(t.root, f.relDir));
    if (f.decision === "replace") {
      const path = this.safeJoin(t.root, [...f.relDir, f.name]);
      return { fh: await open(path, "w"), path };
    }
    for (let n = 0, retried = false; n < 10_000; n++) {
      const path = this.safeJoin(t.root, [...f.relDir, n === 0 ? f.name : numberedName(f.name, n)]);
      try {
        return { fh: await open(path, "wx"), path };
      } catch (err) {
        const code = (err as NodeJS.ErrnoException).code;
        if (code === "ENOENT" && !retried) {
          // Folder vanished under us (user deleted it): recreate once and retry this name.
          retried = true;
          this.knownDirs.clear();
          await this.ensureDir(dirname(path));
          n--;
          continue;
        }
        if (code !== "EEXIST") throw err;
      }
    }
    throw new ProtocolError("DISK_WRITE", "no free name");
  }

  async completeFile(t: TransferRec, fileId: string, root: string): Promise<string> {
    const f = t.byId.get(fileId);
    if (!f) throw new ProtocolError("NOT_FOUND");
    if (f.state === "complete") return f.finalName ?? f.name;
    if (f.state === "skipped") return f.name;
    if (!f.received.complete) throw new ProtocolError("INCOMPLETE");
    const hasher = await this.hasher(t.integrity);
    const ours = hasher.root(f.digests ?? new Uint8Array(0));
    if (ours !== root) {
      // Sender's file differs from what we assembled: throw the copy away.
      this.opts.log.warn(`root mismatch on ${t.id}/${f.id}; discarding partial file`);
      await this.closeHandle(t, f);
      await rm(this.partPath(t, f), { force: true });
      t.bytesDone -= f.size;
      f.received = new Bitset(f.blocks);
      f.digests = null;
      f.state = "new";
      this.touch(t);
      throw new ProtocolError("INTEGRITY");
    }
    await this.finalizeFile(t, f);
    await this.checkDone(t);
    return f.finalName ?? f.name;
  }

  async cancel(t: TransferRec): Promise<void> {
    t.cancelled = true;
    for (const f of t.files) await this.closeHandle(t, f);
    this.transfers.delete(t.id);
    const timer = this.persistTimers.get(t.id);
    if (timer) clearTimeout(timer);
    if (t.bench) return;
    await rm(this.partDir(t), { recursive: true, force: true });
    await rm(this.statePath(t), { force: true });
    if (t.direction === "to-guest") await rm(t.root, { recursive: true, force: true });
    this.opts.log.info(`transfer ${t.id} cancelled`);
  }

  // ---------------------------------------------------------------------------
  // Outbox (PC -> iPhone)

  offers(): Offer[] {
    const out: Offer[] = [];
    for (const t of this.transfers.values()) {
      if (t.direction !== "to-guest" || t.cancelled || t.filesDone < t.files.length) continue;
      out.push({
        transferId: t.id,
        label: t.label,
        createdAt: t.createdAt,
        totalBytes: t.bytesTotal,
        files: t.files.map((f) => ({ id: f.id, name: f.name, relDir: f.relDir.join("/"), size: f.size, type: f.type })),
      });
    }
    return out.sort((a, b) => b.createdAt - a.createdAt);
  }

  outboxFilePath(t: TransferRec, fileId: string): { path: string; file: FileRec } {
    const f = t.byId.get(fileId);
    if (!f || t.direction !== "to-guest" || f.state !== "complete") throw new ProtocolError("NOT_FOUND");
    return { path: join(t.root, f.id), file: f };
  }

  /** Load outbox offers left over from an earlier run and drop stale state. */
  async restore(): Promise<void> {
    await this.ensureDir(this.opts.outboxDir);
    for (const name of await readdir(this.opts.outboxDir).catch(() => [] as string[])) {
      if (!name.endsWith(".json")) continue;
      const id = name.slice(0, -5);
      const t = await this.find(id);
      if (t && Date.now() - t.createdAt > 24 * 3600_000) await this.cancel(t);
    }
  }

  async flushAll(): Promise<void> {
    for (const t of this.transfers.values()) if (t.dirty) await this.persist(t);
    for (const [key, h] of this.handles) {
      this.handles.delete(key);
      await (await h.fh.catch(() => null))?.close().catch(() => undefined);
    }
  }

  // ---------------------------------------------------------------------------

  private async finalizeFile(t: TransferRec, f: FileRec) {
    await this.closeHandle(t, f);
    if (!t.bench) {
      const part = this.partPath(t, f);
      if (!existsSync(part)) await writeFile(part, new Uint8Array(0));
      try {
        await this.withNamingLock(async () => {
          const target = t.direction === "to-guest" ? join(t.root, f.id) : await this.pickFinalPath(t, f);
          await mkdir(dirname(target), { recursive: true });
          await rename(part, target).catch(async (err: NodeJS.ErrnoException) => {
            // Replacing a file another program holds open fails on Windows: keep both instead.
            if (f.decision !== "replace" || (err.code !== "EPERM" && err.code !== "EBUSY")) throw err;
            f.decision = "keep-both";
            const alt = await this.pickFinalPath(t, f);
            await rename(part, alt);
            f.finalName = relName(t.root, alt);
          });
          if (!f.finalName) f.finalName = relName(t.root, target);
        });
      } catch (err) {
        throw diskError(err);
      }
    }
    f.state = "complete";
    f.digests = null;
    t.filesDone++;
    this.touch(t);
  }

  private async checkDone(t: TransferRec) {
    if (t.filesDone + t.files.filter((f) => f.state === "skipped").length < t.files.length) return;
    if (t.direction === "to-host" && !t.bench) {
      // Nothing left to resume: leave only the user's files behind, no bookkeeping.
      t.finished = true;
      const timer = this.persistTimers.get(t.id);
      if (timer) clearTimeout(timer);
      this.persistTimers.delete(t.id);
      await rm(this.partDir(t), { recursive: true, force: true });
      await rm(this.statePath(t), { force: true });
      await rmdir(join(t.root, STATE_DIR)).catch(() => undefined); // only succeeds when empty
    } else {
      await this.persist(t);
    }
    this.opts.hooks.completed(t);
    this.opts.log.info(`transfer ${t.id} complete (${t.filesDone} files)`);
  }

  /** Final location honoring the conflict decision. Must run under the naming lock. */
  private async pickFinalPath(t: TransferRec, f: FileRec): Promise<string> {
    const base = this.safeJoin(t.root, [...f.relDir, f.name]);
    if (f.decision === "replace") return base;
    if (!(await exists(base))) return base;
    for (let n = 1; n < 10_000; n++) {
      const candidate = this.safeJoin(t.root, [...f.relDir, numberedName(f.name, n)]);
      if (!(await exists(candidate))) return candidate;
    }
    throw new ProtocolError("DISK_WRITE", "no free name");
  }

  private safeJoin(root: string, segments: string[]): string {
    const target = resolve(root, ...segments);
    if (target !== root && !target.startsWith(root.endsWith(sep) ? root : root + sep)) throw new ProtocolError("FORBIDDEN", "path escapes root");
    return target;
  }

  private withNamingLock<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.namingLock.then(fn, fn);
    this.namingLock = run.catch(() => undefined);
    return run;
  }

  /** One open handle per part file, shared by concurrent writers; opened at most once. */
  private async handle(t: TransferRec, f: FileRec) {
    const key = `${t.id}/${f.id}`;
    let h = this.handles.get(key);
    if (h) {
      h.used = Date.now();
      return h;
    }
    if (this.handles.size >= MAX_OPEN_HANDLES) {
      const idle = [...this.handles.entries()].filter(([, v]) => v.busy === 0).sort((a, b) => a[1].used - b[1].used)[0];
      if (idle) {
        this.handles.delete(idle[0]);
        await (await idle[1].fh).close().catch(() => undefined);
      }
    }
    // O_CREAT without O_TRUNC: resuming must keep what's already there.
    const path = this.partPath(t, f);
    h = {
      fh: mkdir(dirname(path), { recursive: true }).then(() => open(path, FS.O_RDWR | FS.O_CREAT)),
      used: Date.now(),
      busy: 0,
    };
    this.handles.set(key, h);
    h.fh.catch(() => this.handles.delete(key));
    return h;
  }

  private async closeHandle(t: TransferRec, f: FileRec) {
    const key = `${t.id}/${f.id}`;
    const h = this.handles.get(key);
    if (!h) return;
    this.handles.delete(key);
    while (h.busy > 0) await new Promise((r) => setTimeout(r, 5));
    await (await h.fh).close().catch(() => undefined);
  }

  private async hasher(algo: HashAlgo): Promise<BlockHasher> {
    let h = this.hashers.get(algo);
    if (!h) {
      h = await createBlockHasher(algo);
      this.hashers.set(algo, h);
    }
    return h;
  }

  private touch(t: TransferRec) {
    t.dirty = true;
    this.opts.hooks.progress(t);
    if (t.bench || this.persistTimers.has(t.id)) return;
    this.persistTimers.set(
      t.id,
      setTimeout(() => {
        this.persistTimers.delete(t.id);
        void this.persist(t).catch((err) => this.opts.log.warn(`persist failed for ${t.id}`, err));
      }, 1000),
    );
  }

  private partDir(t: Pick<TransferRec, "root" | "direction" | "id">) {
    return t.direction === "to-host" ? join(t.root, STATE_DIR, t.id) : t.root;
  }

  private partPath(t: TransferRec, f: FileRec) {
    return join(this.partDir(t), `${f.id}.part`);
  }

  private statePath(t: Pick<TransferRec, "root" | "direction" | "id">) {
    return t.direction === "to-host" ? join(t.root, STATE_DIR, `${t.id}.json`) : join(this.opts.outboxDir, `${t.id}.json`);
  }

  /** Absolute paths of the files that landed, for "Show in folder". */
  landedPaths(t: TransferRec): string[] {
    return t.files.filter((f) => f.state === "complete" && f.finalName).map((f) => this.safeJoin(t.root, f.finalName!.split("/")));
  }

  private async persist(t: TransferRec) {
    if (t.bench || t.cancelled || t.finished) return;
    t.dirty = false;
    const data: Persisted = {
      v: 1,
      id: t.id,
      direction: t.direction,
      label: t.label,
      integrity: t.integrity,
      deviceId: t.deviceId,
      deviceName: t.deviceName,
      createdAt: t.createdAt,
      root: t.root,
      files: t.files.map((f) => {
        const p: PersistedFile = {
          id: f.id,
          name: f.name,
          relDir: f.relDir,
          size: f.size,
          type: f.type,
          lastModified: f.lastModified,
          decision: f.decision,
          state: f.state,
        };
        if (f.state === "partial") {
          p.received = f.received.toBase64();
          if (f.digests) p.digests = bytesToBase64Url(f.digests);
        }
        if (f.finalName) p.finalName = f.finalName;
        return p;
      }),
    };
    const path = this.statePath(t);
    await this.ensureDir(dirname(path));
    await writeFile(`${path}.tmp`, JSON.stringify(data));
    await rename(`${path}.tmp`, path);
  }

  private async find(id: string): Promise<TransferRec | null> {
    const live = this.transfers.get(id);
    if (live) return live;
    const candidates = [
      join(resolve(this.opts.destination()), STATE_DIR, `${id}.json`),
      join(this.opts.outboxDir, `${id}.json`),
    ];
    for (const p of candidates) {
      const raw = await readFile(p, "utf8").catch(() => null);
      if (!raw) continue;
      try {
        const t = this.revive(JSON.parse(raw) as Persisted);
        this.transfers.set(t.id, t);
        return t;
      } catch (err) {
        this.opts.log.warn(`unreadable transfer state ${p}`, err);
      }
    }
    return null;
  }

  private revive(p: Persisted): TransferRec {
    if (p.v !== 1) throw new Error("unknown state version");
    const len = HASH_LENGTH[p.integrity];
    const files: FileRec[] = p.files.map((pf) => {
      const blocks = Math.ceil(pf.size / BLOCK_SIZE);
      const received = pf.state === "complete" ? full(blocks) : pf.received ? Bitset.fromBase64(blocks, pf.received) : new Bitset(blocks);
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
        blocks,
        decision: pf.decision,
        state: pf.state,
        received,
        digests,
        ...(pf.finalName ? { finalName: pf.finalName } : {}),
      };
    });
    const t: TransferRec = {
      id: p.id,
      direction: p.direction,
      label: p.label,
      integrity: p.integrity,
      bench: false,
      deviceId: p.deviceId,
      deviceName: p.deviceName,
      createdAt: p.createdAt,
      root: p.root,
      files,
      byId: new Map(files.map((f) => [f.id, f])),
      bytesTotal: files.reduce((s, f) => s + f.size, 0),
      bytesDone: 0,
      filesDone: files.filter((f) => f.state === "complete").length,
      cancelled: false,
      dirty: false,
    };
    for (const f of files) {
      if (f.state === "complete") t.bytesDone += f.size;
      else if (f.state === "partial") t.bytesDone += Math.min(f.size, f.received.count * BLOCK_SIZE);
    }
    return t;
  }

  private assertSameManifest(t: TransferRec, input: CreateInput) {
    if (t.direction !== input.direction || t.files.length !== input.files.length) throw new ProtocolError("BAD_REQUEST", "manifest changed");
    for (const f of input.files) {
      const mine = t.byId.get(f.id);
      if (!mine || mine.size !== f.size) throw new ProtocolError("BAD_REQUEST", "manifest changed");
    }
  }

  private async assertSpace(root: string, bytes: number) {
    try {
      const s = await statfs(root);
      if (Number(s.bavail) * Number(s.bsize) < bytes + 64e6) throw new ProtocolError("DISK_FULL");
    } catch (err) {
      if (err instanceof ProtocolError) throw err;
      /* statfs unsupported: let writes report it */
    }
  }

  private readonly knownDirs = new Set<string>();
  private async ensureDir(dir: string) {
    if (this.knownDirs.has(dir)) return;
    try {
      await mkdir(dir, { recursive: true });
      if (this.knownDirs.size > 10_000) this.knownDirs.clear();
      this.knownDirs.add(dir);
    } catch (err) {
      throw diskError(err);
    }
  }
}

function diskError(err: unknown): ProtocolError {
  if (err instanceof ProtocolError) return err;
  const code = (err as NodeJS.ErrnoException)?.code;
  if (code === "ENOSPC" || code === "EDQUOT") return new ProtocolError("DISK_FULL");
  return new ProtocolError("DISK_WRITE", String((err as Error)?.message ?? err));
}

async function exists(p: string): Promise<boolean> {
  return stat(p).then(
    () => true,
    () => false,
  );
}

/** The resume-state folder is bookkeeping, not content: keep it out of Explorer. */
function hideOnWindows(dir: string) {
  if (process.platform !== "win32") return;
  spawn("attrib", ["+h", dir], { stdio: "ignore", windowsHide: true }).on("error", () => undefined);
}

function relName(root: string, target: string): string {
  return target.slice(root.length + 1).split(sep).join("/");
}

function safeB64(s: string): Uint8Array | null {
  try {
    return base64UrlToBytes(s);
  } catch {
    return null;
  }
}

function full(n: number): Bitset {
  const b = new Bitset(n);
  for (let i = 0; i < n; i++) b.set(i);
  return b;
}

async function forEachLimit<T>(items: T[], limit: number, fn: (item: T) => Promise<void>) {
  let i = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) await fn(items[i++]!);
  });
  await Promise.all(workers);
}
