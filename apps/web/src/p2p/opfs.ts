import type { FileSink, SinkFactory, StateStore } from "@swiftdrop/peer";

/**
 * Received files live in the Origin Private File System: disk-backed, written at their
 * offset as chunks arrive, never gathered in memory. Layout:
 *   swiftdrop/<transferId>/<fileId>       data of a large file
 *   swiftdrop/<transferId>/pack           small files from batch frames, back to back
 *   swiftdrop/<transferId>/pack.index     "<fileId>	<offset>	<size>" per small file
 *   swiftdrop/state/<transferId>.json     resume state
 */

const ROOT = "swiftdrop";
const NL = String.fromCharCode(10);
const TAB = String.fromCharCode(9);

export function opfsAvailable(): boolean {
  return typeof navigator !== "undefined" && typeof navigator.storage?.getDirectory === "function" && isSecureContext;
}

type Pending = { resolve: () => void; reject: (e: Error) => void };
type WorkerMsg = { ready?: boolean; sync?: boolean; id?: number; ok?: boolean; name?: string; message?: string };

/** Writes through a worker's sync access handles; falls back to createWritable() on the main thread. */
export class OpfsSinkFactory implements SinkFactory {
  private worker: Worker | null = null;
  private readonly workerReady: Promise<boolean>;
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();
  /** For the debug panel: bytes handed to storage and time until the worker confirmed them. */
  readonly stats = { bytes: 0, writes: 0, busyMs: 0 };

  constructor() {
    this.workerReady = new Promise<boolean>((resolve) => {
      try {
        const w = new Worker(new URL("./opfs-worker.ts", import.meta.url), { type: "module" });
        const timer = setTimeout(() => resolve(false), 3000);
        w.onmessage = (ev: MessageEvent<WorkerMsg>) => {
          const d = ev.data;
          if (d.ready) {
            clearTimeout(timer);
            this.worker = d.sync ? w : null;
            if (!d.sync) w.terminate();
            resolve(Boolean(d.sync));
            return;
          }
          const p = this.pending.get(d.id!);
          if (!p) return;
          this.pending.delete(d.id!);
          if (d.ok) p.resolve();
          else {
            const e = new Error(d.message);
            e.name = d.name ?? "Error";
            p.reject(e);
          }
        };
        w.onerror = () => {
          clearTimeout(timer);
          resolve(false);
        };
      } catch {
        resolve(false);
      }
    });
  }

  /** "worker" (sync access handles) or "writable" (main-thread fallback). For the diagnostics line. */
  async mode(): Promise<"worker" | "writable"> {
    return (await this.workerReady) ? "worker" : "writable";
  }

  async open(transferId: string, fileId: string, size: number): Promise<FileSink> {
    const path = [ROOT, transferId, fileId];
    if (await this.workerReady) {
      await this.post({ op: "open", path, size });
      return {
        write: (at, bytes, owned) => {
          // Owned buffers move to the worker; anything else is copied first so the
          // caller's memory is never detached under it.
          const len = bytes.byteLength;
          const buf = owned ? (bytes.buffer as ArrayBuffer) : bytes.slice().buffer;
          return this.timed(len, this.post({ op: "write", path, at, bytes: buf, off: owned ? bytes.byteOffset : 0, len }, [buf]));
        },
        close: () => this.post({ op: "close", path }),
      };
    }
    return writableSink(path, size);
  }

  /** A whole batch frame in one message: the worker appends every file in it to the pack. */
  async writeFiles(transferId: string, frame: Uint8Array, files: Array<{ fileId: string; offset: number; size: number }>) {
    this.packs.delete(transferId);
    if (!(await this.workerReady)) {
      for (const f of files) {
        const sink = await writableSink([ROOT, transferId, f.fileId], f.size);
        if (f.size) await sink.write(0, frame.subarray(f.offset, f.offset + f.size));
        await sink.close();
      }
      return;
    }
    const buf = frame.buffer as ArrayBuffer;
    await this.timed(files.reduce((n, f) => n + f.size, 0), this.post({ op: "files", dir: [ROOT, transferId], bytes: buf, files: files.map((f) => ({ name: f.fileId, off: frame.byteOffset + f.offset, len: f.size })) }, [buf]));
  }

  async discard(transferId: string, fileId: string) {
    const d = await dir([ROOT, transferId]).catch(() => null);
    await d?.removeEntry(fileId).catch(() => undefined);
  }

  async remove(transferId: string) {
    this.packs.delete(transferId);
    const d = await dir([ROOT]).catch(() => null);
    await d?.removeEntry(transferId, { recursive: true }).catch(() => undefined);
  }

  async file(transferId: string, fileId: string, name: string, type: string): Promise<File> {
    const d = await dir([ROOT, transferId]);
    const packed = (await this.packIndex(transferId, d)).get(fileId);
    if (packed) {
      // A slice of the disk-backed pack: still nothing read into memory.
      const pack = await (await d.getFileHandle("pack")).getFile();
      return new File([pack.slice(packed.off, packed.off + packed.len)], name, { type: type || "application/octet-stream", lastModified: pack.lastModified });
    }
    const f = await (await d.getFileHandle(fileId)).getFile();
    // A File built from a disk-backed File references it; nothing is read into memory here.
    return new File([f], name, { type: type || "application/octet-stream", lastModified: f.lastModified });
  }

  private readonly packs = new Map<string, Promise<Map<string, { off: number; len: number }>>>();

  private packIndex(transferId: string, d: FileSystemDirectoryHandle) {
    let p = this.packs.get(transferId);
    if (!p) {
      p = (async () => {
        const out = new Map<string, { off: number; len: number }>();
        const text = await d
          .getFileHandle("pack.index")
          .then((h) => h.getFile())
          .then((f) => f.text())
          .catch(() => "");
        for (const line of text.split(NL)) {
          const [id, off, len] = line.split(TAB);
          if (id && off !== undefined && len !== undefined) out.set(id, { off: Number(off), len: Number(len) });
        }
        return out;
      })();
      this.packs.set(transferId, p);
    }
    return p;
  }

  private async timed(bytes: number, p: Promise<void>): Promise<void> {
    const t0 = performance.now();
    await p;
    this.stats.busyMs += performance.now() - t0;
    this.stats.bytes += bytes;
    this.stats.writes++;
  }

  private post(msg: Record<string, unknown>, transfer: Transferable[] = []): Promise<void> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker!.postMessage({ ...msg, id }, transfer);
    });
  }
}

interface Writable {
  write(chunk: { type: "write"; position: number; data: Uint8Array } | string): Promise<void>;
  truncate(size: number): Promise<void>;
  close(): Promise<void>;
}
type WritableHandle = FileSystemFileHandle & { createWritable?(o?: { keepExistingData: boolean }): Promise<Writable> };

/** Main-thread fallback: one writable per file, positional writes, committed on close. */
async function writableSink(path: string[], size: number): Promise<FileSink> {
  const d = await dir(path.slice(0, -1));
  const fh = (await d.getFileHandle(path[path.length - 1]!, { create: true })) as WritableHandle;
  if (!fh.createWritable) throw Object.assign(new Error("This browser can't save received files."), { name: "NotSupportedError" });
  const existing = (await fh.getFile()).size;
  const w = await fh.createWritable({ keepExistingData: true });
  if (existing > size) await w.truncate(size);
  let chain = Promise.resolve();
  return {
    write(at, bytes) {
      const copy = bytes.slice();
      chain = chain.then(() => w.write({ type: "write", position: at, data: copy }));
      return chain;
    },
    close() {
      chain = chain.then(() => w.close());
      return chain;
    },
  };
}

async function dir(path: string[]): Promise<FileSystemDirectoryHandle> {
  let d = await navigator.storage.getDirectory();
  for (const seg of path) d = await d.getDirectoryHandle(seg, { create: true });
  return d;
}

/** Resume state: small JSON. OPFS when writable, localStorage otherwise. */
export class OpfsStateStore implements StateStore {
  async load(id: string) {
    try {
      const d = await dir([ROOT, "state"]);
      return await (await (await d.getFileHandle(`${id}.json`)).getFile()).text();
    } catch {
      return safeLocal(() => localStorage.getItem(`sd.p2p.${id}`));
    }
  }
  async save(id: string, json: string) {
    try {
      const d = await dir([ROOT, "state"]);
      const fh = (await d.getFileHandle(`${id}.json`, { create: true })) as WritableHandle;
      if (!fh.createWritable) throw new Error("no createWritable");
      const w = await fh.createWritable();
      await w.write(json);
      await w.close();
    } catch {
      safeLocal(() => localStorage.setItem(`sd.p2p.${id}`, json));
    }
  }
  async remove(id: string) {
    const d = await dir([ROOT, "state"]).catch(() => null);
    await d?.removeEntry(`${id}.json`).catch(() => undefined);
    safeLocal(() => localStorage.removeItem(`sd.p2p.${id}`));
  }
}

function safeLocal<T>(fn: () => T): T | null {
  try {
    return fn();
  } catch {
    return null;
  }
}
