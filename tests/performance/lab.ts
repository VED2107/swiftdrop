/**
 * Shared pieces for the benchmark suite.
 *
 * The receiver runs in its own Node process, like in real use. Sharing one event loop
 * between sender and receiver (the old harness) makes each stall the other and makes
 * CPU numbers meaningless, because nobody can tell whose CPU it was.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { execSync } from "node:child_process";
import { mkdtemp, open, rm, type FileHandle } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { PipelineMetrics } from "../../apps/server/src/store.ts";

export const MB = 1e6;
export const MiB = 1 << 20;
const REPO = resolve(import.meta.dirname, "..", "..");

export interface ServerStats {
  cpuUserMs: number;
  cpuSystemMs: number;
  rss: number;
  heapUsed: number;
  writeLoad: number;
  pipeline: PipelineMetrics;
}

export interface LabServer {
  /** base URL as the phone sees it */
  base: string;
  token: string;
  dest: string;
  stats(): Promise<ServerStats>;
  close(): Promise<void>;
}

async function freePort(): Promise<number> {
  return new Promise((res, rej) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => {
      const port = (s.address() as { port: number }).port;
      s.close(() => res(port));
    });
    s.on("error", rej);
  });
}

/** Starts the real server (apps/server) in a child process and pairs a "phone" with it. */
export async function startServer(opts: { dest?: string; env?: Record<string, string>; nodeArgs?: string[] } = {}): Promise<LabServer> {
  const port = await freePort();
  const root = await mkdtemp(join(tmpdir(), "sd-lab-"));
  const dest = opts.dest ?? join(root, "dest");
  const child: ChildProcess = spawn(process.execPath, [...(opts.nodeArgs ?? []), ...(process.env.SD_SERVER_NODE_ARGS?.split(" ").filter(Boolean) ?? []), "--import", "tsx", "--import", pathToFileURL(join(REPO, "tests/performance/exit-on-message.mjs")).href, join(REPO, "apps/server/src/main.ts")], {
    cwd: REPO,
    stdio: ["ignore", "ignore", "inherit", "ipc"],
    env: {
      ...process.env,
      SWIFTDROP_E2E: "1",
      SWIFTDROP_PORT: String(port),
      SWIFTDROP_BIND: "127.0.0.1",
      SWIFTDROP_DEST: dest,
      SWIFTDROP_STATE_DIR: join(root, "state"),
      SWIFTDROP_OUTBOX: join(root, "outbox"),
      SWIFTDROP_WEB_ROOT: join(REPO, "apps/web/dist"),
      SWIFTDROP_MAX_FILE_BYTES: String(1e13),
      SWIFTDROP_LOG: "warn",
      ...opts.env,
    },
  });
  const host = `http://localhost:${port}`;
  const base = `http://127.0.0.1:${port}`;
  for (let i = 0; ; i++) {
    try {
      if ((await fetch(`${host}/api/ping`)).ok) break;
    } catch {
      if (i > 200) throw new Error("server did not start");
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  const token = await pair(host, base);
  return {
    base,
    token,
    dest,
    async stats() {
      return (await (await fetch(`${base}/api/stats`, { headers: { authorization: `Bearer ${token}` } })).json()) as ServerStats;
    },
    async close() {
      // A clean exit writes --cpu-prof / --heap-prof output.
      child.send("exit");
      const killer = setTimeout(() => child.kill(), 5000);
      await new Promise((r) => child.once("exit", r));
      clearTimeout(killer);
      await rm(root, { recursive: true, force: true }).catch(() => undefined);
    },
  };
}

async function pair(host: string, base: string): Promise<string> {
  const json = { "content-type": "application/json" };
  const { code } = (await (await fetch(`${host}/api/host/pairing`)).json()) as { code: string };
  const { requestId } = (await (await fetch(`${base}/api/join`, { method: "POST", headers: { ...json, origin: base }, body: JSON.stringify({ code, deviceName: "bench" }) })).json()) as {
    requestId: string;
  };
  await fetch(`${host}/api/host/joins/${requestId}`, { method: "POST", headers: { ...json, origin: host }, body: JSON.stringify({ approve: true }) });
  return ((await (await fetch(`${base}/api/join/${requestId}`)).json()) as { token: string }).token;
}

// ---------------------------------------------------------------------------
// Source files

/**
 * A Blob-like view of a byte range of a file on disk, read with positional reads.
 * This is what a browser File is to the engine: `slice()` is free, `arrayBuffer()`
 * reads from disk into a fresh buffer. (Node's own openAsBlob reads ~4x slower than
 * fs.read — see primitives.ts — and would make the bench measure Node, not SwiftDrop.)
 */
export function diskBlob(fh: FileHandle, sourceSize: number, from: number, to: number): Blob {
  const make = (a: number, b: number): Blob =>
    ({
      size: b - a,
      type: "",
      slice: (s = 0, e = b - a) => make(a + Math.max(0, s), a + Math.min(e, b - a)),
      arrayBuffer: async () => {
        const out = new Uint8Array(b - a);
        for (let o = 0; o < out.length; ) {
          // Positions past the end of the source wrap around: big virtual files, small real one.
          const pos = (a + o) % sourceSize;
          const { bytesRead } = await fh.read(out, o, Math.min(out.length - o, sourceSize - pos), pos);
          if (bytesRead === 0) throw new Error("short read");
          o += bytesRead;
        }
        return out.buffer;
      },
    }) as unknown as Blob;
  return make(from, to);
}

/** One on-disk file of `bytes` of incompressible-looking data; sources wrap around it. */
export async function makeSource(bytes: number): Promise<{ fh: FileHandle; path: string; size: number; dispose(): Promise<void> }> {
  const dir = await mkdtemp(join(tmpdir(), "sd-src-"));
  const path = join(dir, "source.bin");
  const w = await open(path, "w");
  const chunk = new Uint8Array(MiB);
  for (let b = 0; b < bytes / MiB; b++) {
    let x = (b + 1) * 2654435761;
    for (let i = 0; i < chunk.length; i++) {
      x ^= x << 13;
      x ^= x >>> 17;
      x ^= x << 5;
      chunk[i] = x & 255;
    }
    await w.write(chunk);
  }
  await w.close();
  const fh = await open(path, "r");
  return {
    fh,
    path,
    size: bytes,
    async dispose() {
      await fh.close();
      await rm(dir, { recursive: true, force: true });
    },
  };
}

export function gitRev(): string {
  try {
    const sha = execSync("git rev-parse --short HEAD", { cwd: REPO }).toString().trim();
    const dirty = execSync("git status --porcelain", { cwd: REPO }).toString().trim() ? "+dirty" : "";
    return sha + dirty;
  } catch {
    return "unknown";
  }
}

export function pct(values: number[], p: number): number {
  if (!values.length) return 0;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]!;
}
