import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setLogLevel } from "@swiftdrop/shared";
import { HttpTransport, type SourceFile } from "@swiftdrop/transfer-engine";
import { createApp, type App } from "../../apps/server/src/app.ts";
import type { ServerConfig } from "../../apps/server/src/config.ts";

setLogLevel("error");

export interface TestServer {
  app: App;
  base: string;
  dirs: { dest: string; outbox: string; state: string; root: string };
  hostFetch: (path: string, init?: RequestInit) => Promise<Response>;
  stop(): Promise<void>;
}

/** Requests carrying `x-test-role: host` act as the PC; everything else is a LAN guest. */
export async function startServer(opts: { root?: string; port?: number } = {}): Promise<TestServer> {
  const root = opts.root ?? (await mkdtemp(join(tmpdir(), "swiftdrop-test-")));
  const dirs = { root, dest: join(root, "dest"), outbox: join(root, "outbox"), state: join(root, "state") };
  const config: ServerConfig = {
    port: opts.port ?? 0,
    bindAddress: "127.0.0.1",
    destination: dirs.dest,
    outboxDir: dirs.outbox,
    stateDir: dirs.state,
    webRoot: join(root, "no-web"),
    maxFileSize: 1e12,
    pairingTtlMs: 60_000,
    deviceIdleTtlMs: 3600_000,
    logLevel: "error",
    openBrowser: false,
    isHostRequest: (req) => req.headers["x-test-role"] === "host",
  };
  const app = createApp(config);
  const port = await app.listen();
  const base = `http://127.0.0.1:${port}`;
  return {
    app,
    base,
    dirs,
    hostFetch: (path, init = {}) => fetch(base + path, { ...init, headers: { ...(init.headers as Record<string, string>), "x-test-role": "host" } }),
    async stop() {
      await app.close();
    },
  };
}

export async function cleanup(s: TestServer) {
  await rm(s.dirs.root, { recursive: true, force: true }).catch(() => undefined);
}

/** Runs the full pairing handshake and returns the guest's bearer token. */
export async function pairGuest(s: TestServer, name = "Test iPhone"): Promise<string> {
  const pairing = (await (await s.hostFetch("/api/host/pairing")).json()) as { url: string | null; code: string };
  const joinRes = await fetch(`${s.base}/api/join`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: pairing.code, deviceName: name }),
  });
  const { requestId } = (await joinRes.json()) as { requestId: string };
  const pending = (await (await fetch(`${s.base}/api/join/${requestId}`)).json()) as { status: string };
  if (pending.status !== "pending") throw new Error("expected pending");
  await s.hostFetch(`/api/host/joins/${requestId}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ approve: true }),
  });
  const done = (await (await fetch(`${s.base}/api/join/${requestId}`)).json()) as { status: string; token: string };
  if (done.status !== "approved") throw new Error("pairing failed");
  return done.token;
}

export function guestTransport(s: TestServer, token: string) {
  return new HttpTransport({ baseUrl: s.base, token });
}

/** Deterministic pseudo-random bytes so corruption can't hide behind zeros. */
export function bytes(n: number, seed = 1): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(n);
  let x = seed * 2654435761;
  for (let i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    out[i] = x & 255;
  }
  return out;
}

let fileCounter = 0;
export function source(name: string, data: Uint8Array<ArrayBuffer>, relDir = "", lastModified = 1_700_000_000_000): SourceFile {
  return {
    id: `file_${String(++fileCounter).padStart(6, "0")}`,
    name,
    relDir,
    size: data.byteLength,
    type: "application/octet-stream",
    lastModified,
    blob: new Blob([data]),
  };
}
