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
  | { id: number; op: "write"; path: string[]; at: number; bytes: ArrayBuffer }
  | { id: number; op: "close"; path: string[] };

const handles = new Map<string, Promise<SyncHandle>>();

async function dirFor(path: string[]): Promise<FileSystemDirectoryHandle> {
  let d = await navigator.storage.getDirectory();
  for (const seg of path.slice(0, -1)) d = await d.getDirectoryHandle(seg, { create: true });
  return d;
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
      const bytes = new Uint8Array(m.bytes);
      let done = 0;
      while (done < bytes.byteLength) done += h.write(bytes.subarray(done), { at: m.at + done });
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
