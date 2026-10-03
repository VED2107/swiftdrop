/// <reference lib="webworker" />
/**
 * OPFS writer. `createSyncAccessHandle()` exists only in dedicated workers; it gives
 * positional, synchronous writes straight to disk (Safari 15.2+, Chrome 102+), so a
 * received chunk is on disk before it is acknowledged and nothing accumulates in memory.
 */

interface SyncHandle {
  write(buf: ArrayBufferView, opts: { at: number }): number;
  flush(): void;
  close(): void;
  truncate(size: number): void;
  getSize(): number;
}

type Req =
  | { id: number; op: "open"; path: string[]; size: number }
  | { id: number; op: "write"; path: string[]; at: number; bytes: ArrayBuffer; off?: number; len?: number }
  | { id: number; op: "close"; path: string[] }
  | { id: number; op: "files"; dir: string[]; bytes: ArrayBuffer; files: Array<{ name: string; off: number; len: number }> };

const NL = String.fromCharCode(10);
const TAB = String.fromCharCode(9);
const handles = new Map<string, Promise<SyncHandle>>();

const dirs = new Map<string, Promise<FileSystemDirectoryHandle>>();

/** Directory handles are cached: a batch of 512 files must not walk the tree 512 times. */
function dirFor(path: string[]): Promise<FileSystemDirectoryHandle> {
  const segs = path.slice(0, -1);
  const k = segs.join("/");
  let d = dirs.get(k);
  if (!d) {
    d = (async () => {
      let h = await navigator.storage.getDirectory();
      for (const seg of segs) h = await h.getDirectoryHandle(seg, { create: true });
      return h;
    })();
    dirs.set(k, d);
    d.catch(() => dirs.delete(k));
  }
  return d;
}

async function syncHandle(d: FileSystemDirectoryHandle, name: string): Promise<SyncHandle> {
  const fh = await d.getFileHandle(name, { create: true });
  return (fh as unknown as { createSyncAccessHandle(): Promise<SyncHandle> }).createSyncAccessHandle();
}

function writeAll(h: SyncHandle, bytes: Uint8Array, at: number) {
  let done = 0;
  while (done < bytes.byteLength) done += h.write(bytes.subarray(done), { at: at + done });
}

function open(path: string[]): Promise<SyncHandle> {
  const k = path.join("/");
  let h = handles.get(k);
  if (!h) {
    h = dirFor(path)
      .then((d) => d.getFileHandle(path[path.length - 1]!, { create: true }))
      .then((f) => (f as unknown as { createSyncAccessHandle(): Promise<SyncHandle> }).createSyncAccessHandle());
    handles.set(k, h);
    h.catch(() => handles.delete(k));
  }
  return h;
}

self.onmessage = async (ev: MessageEvent<Req>) => {
  const m = ev.data;
  try {
    if (m.op === "open") {
      const h = await open(m.path);
      if (h.getSize() > m.size) h.truncate(m.size);
    } else if (m.op === "write") {
      const h = await open(m.path);
      writeAll(h, new Uint8Array(m.bytes, m.off ?? 0, m.len ?? m.bytes.byteLength), m.at);
    } else if (m.op === "files") {
      // Small files from one batch frame: appended to the transfer's pack file, located by an
      // append-only index. Two handles per batch instead of one file (and handle) per file:
      // measured 0.4 ms vs 1.4 ms per 10 KB file in Chromium.
      const d = await dirFor([...m.dir, ""]);
      const pack = await syncHandle(d, "pack");
      const lines: string[] = [];
      try {
        let at = pack.getSize();
        for (const f of m.files) {
          writeAll(pack, new Uint8Array(m.bytes, f.off, f.len), at);
          lines.push([f.name, at, f.len].join(TAB));
          at += f.len;
        }
        pack.flush();
      } finally {
        pack.close();
      }
      const index = await syncHandle(d, "pack.index");
      try {
        writeAll(index, new TextEncoder().encode(lines.join(NL) + NL), index.getSize());
        index.flush();
      } finally {
        index.close();
      }
    } else if (m.op === "close") {
      const k = m.path.join("/");
      const h = handles.get(k);
      handles.delete(k);
      if (h) {
        const s = await h;
        s.flush();
        s.close();
      }
    }
    postMessage({ id: m.id, ok: true });
  } catch (err) {
    postMessage({ id: m.id, ok: false, name: (err as Error)?.name ?? "Error", message: String((err as Error)?.message ?? err) });
  }
};

postMessage({ ready: true, sync: typeof (FileSystemFileHandle.prototype as unknown as Record<string, unknown>).createSyncAccessHandle === "function" });
