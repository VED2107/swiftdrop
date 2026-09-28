import type { FileSink, SinkFactory, StateStore } from "@swiftdrop/peer";

/**
 * Received files live in the Origin Private File System: disk-backed, written at their
 * offset as chunks arrive, never gathered in memory. Layout:
 *   swiftdrop/<transferId>/<fileId>     data
 *   swiftdrop/state/<transferId>.json   resume state
 */

const ROOT = "swiftdrop";

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
        write: (at, bytes) => {
          // A transferable copy: the receiver's reassembly buffer isn't ours to give away.
          const buf = bytes.slice().buffer;
          return this.post({ op: "write", path, at, bytes: buf }, [buf]);
        },
        close: () => this.post({ op: "close", path }),
      };
    }
    return writableSink(path, size);
  }

  async discard(transferId: string, fileId: string) {
    const d = await dir([ROOT, transferId]).catch(() => null);
    await d?.removeEntry(fileId).catch(() => undefined);
  }

  async remove(transferId: string) {
    const d = await dir([ROOT]).catch(() => null);
    await d?.removeEntry(transferId, { recursive: true }).catch(() => undefined);
  }

  async file(transferId: string, fileId: string, name: string, type: string): Promise<File> {
    const d = await dir([ROOT, transferId]);
    const f = await (await d.getFileHandle(fileId)).getFile();
    // A File built from a disk-backed File references it; nothing is read into memory here.
    return new File([f], name, { type: type || "application/octet-stream", lastModified: f.lastModified });
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
