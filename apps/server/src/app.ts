import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { access, mkdir, readFile, stat, writeFile, rm } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { basename, dirname, extname, isAbsolute, join, normalize, resolve, sep } from "node:path";
import { pipeline } from "node:stream/promises";
import QRCode from "qrcode";
import { ZodError } from "zod";
import {
  ApproveJoinSchema,
  BATCH_TARGET_BYTES,
  BLOCK_SIZE,
  CompleteFileSchema,
  CreateTransferSchema,
  HEADERS,
  JoinRequestSchema,
  MAX_BLOCKS_PER_CHUNK,
  PROTOCOL_VERSION,
  ProtocolError,
  SettingsPatchSchema,
  type ProgressEvent,
  type ServerEvent,
} from "@swiftdrop/protocol";
import { createLogger, sanitizeFileName, type Logger } from "@swiftdrop/shared";
import { Auth } from "./auth.ts";
import { saveSettings, type ServerConfig } from "./config.ts";
import { Hub } from "./hub.ts";
import { lanAddresses, localAddressSet } from "./net.ts";
import { TransferStore, type TransferRec } from "./store.ts";
import { writeZip, zipLength, type ZipEntry } from "./zip.ts";

export const VERSION = "0.1.0";

type Role = "host" | "guest";
interface Ctx {
  req: IncomingMessage;
  res: ServerResponse;
  url: URL;
  params: string[];
  role: Role | null;
  deviceId: string | null;
  deviceName: string;
  ip: string;
}
type Handler = (ctx: Ctx) => Promise<void> | void;
interface Route {
  method: string;
  pattern: RegExp;
  access: "public" | "host" | "authed";
  handler: Handler;
}

const ID = "([A-Za-z0-9_-]{6,64})";
const MAX_JSON = 1 << 20;
const MAX_MANIFEST_JSON = 48 << 20;

export interface App {
  server: Server;
  store: TransferStore;
  auth: Auth;
  config: ServerConfig;
  listen(): Promise<number>;
  close(): Promise<void>;
}

export function createApp(config: ServerConfig, log: Logger = createLogger("server")): App {
  const auth = new Auth(config.stateDir, config.pairingTtlMs, config.deviceIdleTtlMs);
  let localAddrs = localAddressSet();
  const addrTimer = setInterval(() => (localAddrs = localAddressSet()), 30_000);
  addrTimer.unref();

  const isHost = config.isHostRequest ?? ((req: IncomingMessage) => localAddrs.has(req.socket.remoteAddress ?? ""));

  // ---- progress fan-out, throttled per transfer ------------------------------------
  const lastEmit = new Map<string, number>();
  const progressOf = (t: TransferRec, state: ProgressEvent["state"]): ProgressEvent => ({
    t: "progress",
    transferId: t.id,
    direction: t.direction,
    label: t.label,
    device: t.deviceName,
    filesDone: t.filesDone,
    filesTotal: t.files.length,
    bytesDone: t.bytesDone,
    bytesTotal: t.bytesTotal,
    state,
  });

  const store: TransferStore = new TransferStore({
    destination: () => config.destination,
    outboxDir: config.outboxDir,
    maxFileSize: () => config.maxFileSize,
    log: log.child("store"),
    hooks: {
      progress(t) {
        if (t.direction !== "to-host" || t.bench) return;
        const now = Date.now();
        if (now - (lastEmit.get(t.id) ?? 0) < 250) return;
        lastEmit.set(t.id, now);
        hub.toHosts(progressOf(t, "active"));
      },
      completed(t) {
        lastEmit.delete(t.id);
        if (t.bench) return;
        if (t.direction === "to-host") hub.toHosts(progressOf(t, "complete"));
        else broadcastOffers();
      },
    },
  });

  const broadcastOffers = () => hub.toAll({ t: "offers", offers: store.offers() });
  const broadcastDevices = () => hub.toHosts({ t: "devices", devices: auth.listDevices() });

  const hub = new Hub(
    (req, token) => {
      if (!originOk(req, true)) return null;
      if (isHost(req)) return { role: "host", deviceId: null };
      const d = auth.authenticate(token);
      return d ? { role: "guest", deviceId: d.id } : null;
    },
    (who, send) => {
      send({ t: "offers", offers: store.offers() });
      if (who.role === "host") {
        send({ t: "devices", devices: auth.listDevices() });
        send({ t: "settings", destination: config.destination });
        for (const j of auth.pendingJoins()) send({ t: "join-request", requestId: j.id, deviceName: j.deviceName, via: j.via });
      }
    },
    (deviceId, delta) => {
      auth.setOnline(deviceId, delta);
      broadcastDevices();
    },
  );

  // ---- request guards --------------------------------------------------------------

  /** DNS-rebinding guard: only answer to names that are actually this machine. */
  function hostOk(req: IncomingMessage): boolean {
    const raw = req.headers.host;
    if (!raw) return false;
    const hostname = raw.startsWith("[") ? raw.slice(0, raw.indexOf("]") + 1) : raw.split(":")[0]!;
    return hostname === "localhost" || hostname === "[::1]" || localAddrs.has(hostname);
  }

  /** CSRF guard: a browser always sends Origin on cross-site writes; it must be us. */
  function originOk(req: IncomingMessage, strict = false): boolean {
    const origin = req.headers.origin;
    if (!origin) return !strict;
    return origin === `http://${req.headers.host}`;
  }

  // ---- routes ------------------------------------------------------------------------

  const routes: Route[] = [];
  const route = (method: string, path: string, access: Route["access"], handler: Handler) =>
    routes.push({ method, pattern: new RegExp(`^${path.replaceAll(":id", ID)}$`), access, handler });

  route("GET", "/api/ping", "public", ({ res }) => void res.writeHead(204).end());

  route("GET", "/api/info", "public", ({ res, role, deviceId, deviceName }) =>
    json(res, 200, {
      role,
      deviceId,
      deviceName: role ? deviceName : null,
      // Folder name only (never the full path) so the phone can say where files land.
      folderName: role ? basename(config.destination) : null,
      version: VERSION,
      protocol: PROTOCOL_VERSION,
    }),
  );

  route("GET", "/api/stats", "authed", ({ res }) => {
    const cpu = process.cpuUsage();
    const mem = process.memoryUsage();
    json(res, 200, { cpuUserMs: cpu.user / 1000, cpuSystemMs: cpu.system / 1000, rss: mem.rss, heapUsed: mem.heapUsed, uptime: process.uptime(), writeLoad: store.load, pipeline: store.metrics() });
  });

  /** Raw-link baseline for the benchmark: reads and discards the body, nothing else. */
  route("POST", "/api/bench/sink", "authed", async ({ req, res }) => {
    await readBody(req, MAX_BLOCKS_PER_CHUNK * BLOCK_SIZE);
    res.writeHead(204).end();
  });

  // pairing ---------------------------------------------------------------------------
  route("GET", "/api/host/pairing", "host", async ({ res, url }) => {
    const p = url.searchParams.get("rotate") === "1" ? auth.rotatePairing() : auth.currentPairing();
    const port = currentPort();
    const addresses = lanAddresses();
    const chosen = addresses.find((a) => a.address === url.searchParams.get("address")) ?? addresses[0];
    const pairUrl = chosen ? `http://${chosen.address}:${port}/#p=${p.token}` : null;
    const qr = pairUrl ? QRCode.create(pairUrl, { errorCorrectionLevel: "M" }).modules : null;
    json(res, 200, {
      code: p.code,
      expiresAt: p.expiresAt,
      url: pairUrl,
      manualUrl: chosen ? `http://${chosen.address}:${port}` : null,
      address: chosen?.address ?? null,
      addresses: addresses.map((a) => ({ address: a.address, interfaceName: a.interfaceName, virtual: a.virtual })),
      qr: qr ? { size: qr.size, bits: Buffer.from(qr.data).toString("base64") } : null,
    });
  });

  route("POST", "/api/join", "public", async ({ req, res, ip }) => {
    const body = JoinRequestSchema.parse(await readJson(req, 4096));
    const join = auth.requestJoin(body, ip);
    hub.toHosts({ t: "join-request", requestId: join.id, deviceName: join.deviceName, via: join.via });
    json(res, 202, { requestId: join.id });
  });

  route("GET", "/api/join/:id", "public", ({ res, params, ip }) => {
    auth.checkRate(`poll:${ip}`, 240, 60_000);
    json(res, 200, auth.pollJoin(params[0]!));
  });

  route("POST", "/api/host/joins/:id", "host", async ({ req, res, params }) => {
    const { approve } = ApproveJoinSchema.parse(await readJson(req, 1024));
    const j = auth.resolveJoin(params[0]!, approve);
    hub.toHosts({ t: "join-resolved", requestId: j.id });
    if (approve) broadcastDevices();
    json(res, 200, { ok: true });
  });

  route("GET", "/api/host/devices", "host", ({ res }) => json(res, 200, { devices: auth.listDevices() }));

  route("DELETE", "/api/host/devices/:id", "host", ({ res, params }) => {
    auth.forget(params[0]!);
    hub.disconnectDevice(params[0]!);
    broadcastDevices();
    json(res, 200, { ok: true });
  });

  // settings -------------------------------------------------------------------------
  route("GET", "/api/host/settings", "host", ({ res }) =>
    json(res, 200, { destination: config.destination, maxFileSize: config.maxFileSize, platform: process.platform }),
  );

  route("PATCH", "/api/host/settings", "host", async ({ req, res }) => {
    const patch = SettingsPatchSchema.parse(await readJson(req, 8192));
    if (patch.destination) config.destination = await validateDestination(patch.destination);
    if (patch.maxFileSize) config.maxFileSize = patch.maxFileSize;
    saveSettings(config);
    hub.toHosts({ t: "settings", destination: config.destination });
    json(res, 200, { destination: config.destination, maxFileSize: config.maxFileSize });
  });

  route("POST", "/api/host/choose-folder", "host", async ({ res }) => {
    const picked = await chooseFolderDialog(config.destination);
    if (picked) {
      config.destination = await validateDestination(picked);
      saveSettings(config);
      hub.toHosts({ t: "settings", destination: config.destination });
    }
    json(res, 200, { destination: config.destination, changed: Boolean(picked) });
  });

  /** Opens Explorer with the files of a finished transfer selected. */
  route("POST", "/api/host/reveal/:id", "host", async ({ res, params }) => {
    const t = await store.get(params[0]!).catch(() => null);
    const paths = t ? store.landedPaths(t) : [];
    const target = paths[0];
    if (process.platform === "win32") {
      // explorer.exe parses its own command line; /select, needs the path as one argument
      if (target) spawn("explorer.exe", [`/select,"${target}"`], { detached: true, stdio: "ignore", windowsVerbatimArguments: true }).unref();
      else spawn("explorer.exe", [config.destination], { detached: true, stdio: "ignore" }).unref();
    } else if (process.platform === "darwin") {
      spawn("open", target ? ["-R", target] : [config.destination], { detached: true, stdio: "ignore" }).unref();
    } else {
      spawn("xdg-open", [target ? dirname(target) : config.destination], { detached: true, stdio: "ignore" }).unref();
    }
    json(res, 200, { ok: true, path: target ?? config.destination });
  });

  route("POST", "/api/host/open-folder", "host", async ({ res }) => {
    await mkdir(config.destination, { recursive: true });
    if (process.platform === "win32") spawn("explorer.exe", [config.destination], { detached: true, stdio: "ignore" }).unref();
    else if (process.platform === "darwin") spawn("open", [config.destination], { detached: true, stdio: "ignore" }).unref();
    else spawn("xdg-open", [config.destination], { detached: true, stdio: "ignore" }).unref();
    json(res, 200, { ok: true });
  });

  // transfers ---------------------------------------------------------------------------
  route("POST", "/api/transfers", "authed", async (ctx) => {
    const input = CreateTransferSchema.parse(await readJson(ctx.req, MAX_MANIFEST_JSON));
    if (!input.bench) {
      if (ctx.role === "guest" && input.direction !== "to-host") throw new ProtocolError("FORBIDDEN");
      if (ctx.role === "host" && input.direction !== "to-guest") throw new ProtocolError("FORBIDDEN");
    }
    const result = await store.create(input, { id: ctx.deviceId ?? "host", name: ctx.deviceName });
    if ("conflicts" in result) return json(ctx.res, 409, result);
    json(ctx.res, 200, result.status);
  });

  route("GET", "/api/transfers/:id", "authed", async ({ res, params }) => json(res, 200, store.status(await store.get(params[0]!))));

  route("PUT", "/api/transfers/:id/files/:id/blocks/(\\d{1,9})", "authed", async ({ req, res, params }) => {
    const t = await store.get(params[0]!);
    const r0 = performance.now();
    const body = await readBody(req, MAX_BLOCKS_PER_CHUNK * BLOCK_SIZE);
    store.noteReceive(body.length, performance.now() - r0);
    await store.writeBlocks(t, params[1]!, Number(params[2]), body, header(req, HEADERS.blockHashes));
    res.writeHead(204, { [HEADERS.serverLoad]: store.load.toFixed(2) }).end();
  });

  route("POST", "/api/transfers/:id/batch", "authed", async ({ req, res, params }) => {
    const t = await store.get(params[0]!);
    const r0 = performance.now();
    const body = await readBody(req, BATCH_TARGET_BYTES + (2 << 20));
    store.noteReceive(body.length, performance.now() - r0);
    await store.writeBatch(t, body);
    res.writeHead(204, { [HEADERS.serverLoad]: store.load.toFixed(2) }).end();
  });

  route("POST", "/api/transfers/:id/files/:id/complete", "authed", async ({ req, res, params }) => {
    const t = await store.get(params[0]!);
    const { root } = CompleteFileSchema.parse(await readJson(req, 1024));
    const finalName = await store.completeFile(t, params[1]!, root);
    json(res, 200, { finalName });
  });

  route("DELETE", "/api/transfers/:id", "authed", async ({ res, params, role, deviceId }) => {
    const t = await store.get(params[0]!);
    if (role === "guest" && t.deviceId !== deviceId) throw new ProtocolError("FORBIDDEN");
    await store.cancel(t);
    if (t.direction === "to-host") hub.toHosts(progressOf(t, "cancelled"));
    else broadcastOffers();
    json(res, 200, { ok: true });
  });

  // offers (PC -> iPhone) -------------------------------------------------------------
  route("GET", "/api/offers", "authed", ({ res }) => json(res, 200, { offers: store.offers() }));

  route("POST", "/api/offers/:id/ticket", "authed", async ({ res, params }) => {
    await store.get(params[0]!);
    json(res, 200, { ticket: auth.signTicket(`offer:${params[0]}`) });
  });

  route("DELETE", "/api/offers/:id", "host", async ({ res, params }) => {
    await store.cancel(await store.get(params[0]!));
    broadcastOffers();
    json(res, 200, { ok: true });
  });

  route("GET", "/api/offers/:id/files/:id", "public", async (ctx) => {
    requireOfferAccess(ctx);
    const t = await store.get(ctx.params[0]!);
    const { path, file } = store.outboxFilePath(t, ctx.params[1]!);
    await sendFile(ctx, path, file.name, file.type, file.size, t);
  });

  route("GET", "/api/offers/:id/zip", "public", async (ctx) => {
    requireOfferAccess(ctx);
    const t = await store.get(ctx.params[0]!);
    const offer = store.offers().find((o) => o.transferId === t.id);
    if (!offer) throw new ProtocolError("NOT_FOUND");
    const used = new Set<string>();
    const entries: ZipEntry[] = offer.files.map((f) => {
      let name = [f.relDir, f.name].filter(Boolean).join("/");
      for (let n = 2; used.has(name.toLowerCase()); n++) name = `${f.name.replace(/(\.[^.]*)?$/, ` (${n})$1`)}`;
      used.add(name.toLowerCase());
      return { name, path: store.outboxFilePath(t, f.id).path, size: f.size, mtime: new Date() };
    });
    const archiveName = `${sanitizeFileName(offer.label || "SwiftDrop")}.zip`;
    ctx.res.writeHead(200, {
      "content-type": "application/zip",
      "content-length": String(zipLength(entries)),
      "content-disposition": disposition(archiveName),
      "cache-control": "no-store",
    });
    let sent = 0;
    const total = zipLength(entries);
    await writeZip(entries, ctx.res, (n) => {
      sent += n;
      downloadProgress(t, sent, total, ctx.deviceName);
    });
    ctx.res.end();
  });

  function requireOfferAccess(ctx: Ctx) {
    if (ctx.role) return;
    if (!auth.verifyTicket(`offer:${ctx.params[0]}`, ctx.url.searchParams.get("ticket"))) throw new ProtocolError("UNAUTHORIZED");
  }

  const dlEmit = new Map<string, number>();
  function downloadProgress(t: TransferRec, done: number, total: number, who: string) {
    const now = Date.now();
    if (done < total && now - (dlEmit.get(t.id) ?? 0) < 400) return;
    dlEmit.set(t.id, now);
    hub.toHosts({
      t: "progress",
      transferId: `${t.id}`,
      direction: "to-guest",
      label: t.label,
      device: who || "iPhone",
      filesDone: done >= total ? t.files.length : 0,
      filesTotal: t.files.length,
      bytesDone: done,
      bytesTotal: total,
      state: done >= total ? "complete" : "active",
    });
  }

  async function sendFile(ctx: Ctx, path: string, name: string, type: string, size: number, t: TransferRec) {
    const { req, res } = ctx;
    const range = parseRange(req.headers.range, size);
    const headers: Record<string, string> = {
      "content-type": safeMime(type),
      "content-disposition": disposition(name),
      "accept-ranges": "bytes",
      "cache-control": "no-store",
    };
    if (range === "invalid") {
      res.writeHead(416, { "content-range": `bytes */${size}` }).end();
      return;
    }
    const [start, end] = range ?? [0, size - 1];
    headers["content-length"] = String(size === 0 ? 0 : end - start + 1);
    if (range) headers["content-range"] = `bytes ${start}-${end}/${size}`;
    res.writeHead(range ? 206 : 200, headers);
    if (req.method === "HEAD" || size === 0) return void res.end();
    let sent = start;
    const stream = createReadStream(path, { start, end, highWaterMark: 1 << 20 });
    stream.on("data", (c) => {
      sent += c.length;
      downloadProgress(t, sent, size, ctx.deviceName);
    });
    await pipeline(stream, res);
  }

  // ---- dispatch ---------------------------------------------------------------------

  const server = createServer({ keepAliveTimeout: 65_000, requestTimeout: 10 * 60_000, headersTimeout: 30_000 }, (req, res) => {
    void dispatch(req, res);
  });
  server.on("upgrade", (req, socket, head) => {
    const path = (req.url ?? "").split("?")[0];
    if (path !== "/api/events" || !hostOk(req)) {
      socket.destroy();
      return;
    }
    hub.upgrade(req, socket, head);
  });

  async function dispatch(req: IncomingMessage, res: ServerResponse) {
    res.setHeader("x-content-type-options", "nosniff");
    res.setHeader("referrer-policy", "no-referrer");
    try {
      if (!hostOk(req)) throw new ProtocolError("FORBIDDEN", "unexpected host header", 421);
      const url = new URL(req.url ?? "/", "http://local");
      if (!url.pathname.startsWith("/api/")) return await serveStatic(req, res, url.pathname);
      if (req.method !== "GET" && req.method !== "HEAD" && !originOk(req)) throw new ProtocolError("FORBIDDEN", "bad origin");

      const method = req.method === "HEAD" ? "GET" : req.method ?? "GET";
      for (const r of routes) {
        if (r.method !== method) continue;
        const m = r.pattern.exec(url.pathname);
        if (!m) continue;
        const ctx = identify(req, res, url, m.slice(1));
        if (r.access === "host" && ctx.role !== "host") throw new ProtocolError("FORBIDDEN");
        if (r.access === "authed" && !ctx.role) throw new ProtocolError("UNAUTHORIZED");
        await r.handler(ctx);
        return;
      }
      throw new ProtocolError("NOT_FOUND");
    } catch (err) {
      fail(res, err);
    }
  }

  function identify(req: IncomingMessage, res: ServerResponse, url: URL, params: string[]): Ctx {
    const ip = req.socket.remoteAddress ?? "";
    const bearer = /^Bearer\s+(.+)$/i.exec(req.headers.authorization ?? "")?.[1];
    if (bearer) {
      const d = auth.authenticate(bearer);
      if (d) return { req, res, url, params, role: "guest", deviceId: d.id, deviceName: d.name, ip };
      if (!isHost(req)) throw new ProtocolError("UNAUTHORIZED");
    }
    if (isHost(req)) return { req, res, url, params, role: "host", deviceId: null, deviceName: "This PC", ip };
    return { req, res, url, params, role: null, deviceId: null, deviceName: "", ip };
  }

  function fail(res: ServerResponse, err: unknown) {
    let pe: ProtocolError;
    if (err instanceof ProtocolError) pe = err;
    else if (err instanceof ZodError) pe = new ProtocolError("BAD_REQUEST", err.issues[0]?.message);
    else if (err instanceof SyntaxError) pe = new ProtocolError("BAD_REQUEST", "invalid JSON");
    else {
      log.error("unhandled", err);
      pe = new ProtocolError("SERVER");
    }
    if (pe.status >= 500 || pe.code === "INTEGRITY") log.warn(`${pe.code}: ${pe.message}`);
    if (res.headersSent) {
      res.destroy();
      return;
    }
    json(res, pe.status, { code: pe.code, message: pe.userMessage });
  }

  // ---- static SPA -------------------------------------------------------------------

  const MIME: Record<string, string> = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".webmanifest": "application/manifest+json",
    ".woff2": "font/woff2",
    ".woff": "font/woff",
    ".json": "application/json",
  };
  const CSP = [
    "default-src 'self'",
    "img-src 'self' blob: data:",
    "media-src 'self' blob:",
    "style-src 'self' 'unsafe-inline'",
    "font-src 'self'",
    "connect-src 'self' ws: wss:",
    "worker-src 'self' blob:",
    "script-src 'self' 'wasm-unsafe-eval'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "form-action 'self'",
  ].join("; ");

  async function serveStatic(req: IncomingMessage, res: ServerResponse, pathname: string) {
    if (req.method !== "GET" && req.method !== "HEAD") throw new ProtocolError("NOT_FOUND");
    const root = resolve(config.webRoot);
    let file = resolve(root, `.${normalize(decodeURIComponent(pathname))}`);
    if (!file.startsWith(root + sep) && file !== root) throw new ProtocolError("NOT_FOUND");
    let st = await stat(file).catch(() => null);
    if (!st?.isFile()) {
      file = join(root, "index.html");
      st = await stat(file).catch(() => null);
      if (!st) {
        res.writeHead(503, { "content-type": "text/plain" }).end("SwiftDrop web app is not built yet. Run: pnpm build");
        return;
      }
    }
    const immutable = file.includes(`${sep}assets${sep}`);
    res.writeHead(200, {
      "content-type": MIME[extname(file)] ?? "application/octet-stream",
      "content-length": String(st.size),
      "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-cache",
      "content-security-policy": CSP,
      "x-frame-options": "DENY",
    });
    if (req.method === "HEAD") return void res.end();
    await pipeline(createReadStream(file), res);
  }

  function currentPort(): number {
    const a = server.address();
    return typeof a === "object" && a ? a.port : config.port;
  }

  return {
    server,
    store,
    auth,
    config,
    async listen() {
      await store.restore();
      await new Promise<void>((r, j) => {
        server.once("error", j);
        server.listen(config.port, config.bindAddress, () => r());
      });
      return currentPort();
    },
    async close() {
      clearInterval(addrTimer);
      hub.close();
      await store.flushAll();
      server.closeAllConnections();
      await new Promise<void>((r) => server.close(() => r()));
    },
  };
}

// ---- helpers ----------------------------------------------------------------------

function json(res: ServerResponse, status: number, body: unknown) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": String(Buffer.byteLength(data)), "cache-control": "no-store" });
  res.end(data);
}

function header(req: IncomingMessage, name: string): string | undefined {
  const v = req.headers[name];
  return Array.isArray(v) ? v[0] : v;
}

/** Reads a request body into one preallocated buffer (no chunk list, no concat copy). */
function readBody(req: IncomingMessage, max: number): Promise<Buffer> {
  const declared = Number(req.headers["content-length"]);
  if (Number.isFinite(declared) && declared > max) return Promise.reject(new ProtocolError("TOO_LARGE"));
  return new Promise((resolvePromise, reject) => {
    if (Number.isFinite(declared) && declared >= 0) {
      const buf = Buffer.allocUnsafe(declared);
      let off = 0;
      req.on("data", (c: Buffer) => {
        if (off + c.length > declared) {
          reject(new ProtocolError("BAD_REQUEST", "body longer than content-length"));
          req.destroy();
          return;
        }
        c.copy(buf, off);
        off += c.length;
      });
      req.on("end", () => (off === declared ? resolvePromise(buf) : reject(new ProtocolError("NETWORK", "body truncated", 400))));
    } else {
      const chunks: Buffer[] = [];
      let n = 0;
      req.on("data", (c: Buffer) => {
        n += c.length;
        if (n > max) {
          reject(new ProtocolError("TOO_LARGE"));
          req.destroy();
          return;
        }
        chunks.push(c);
      });
      req.on("end", () => resolvePromise(Buffer.concat(chunks, n)));
    }
    req.on("error", reject);
    req.on("aborted", () => reject(new ProtocolError("NETWORK", "client aborted", 400)));
  });
}

async function readJson(req: IncomingMessage, max = MAX_JSON): Promise<unknown> {
  const body = await readBody(req, max);
  return JSON.parse(body.toString("utf8"));
}

function parseRange(h: string | undefined, size: number): [number, number] | null | "invalid" {
  if (!h) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(h.trim());
  if (!m) return null; // multi-range etc.: serve the whole thing
  let start: number;
  let end: number;
  if (m[1] === "") {
    const suffix = Number(m[2]);
    if (!suffix) return "invalid";
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (start > end || start >= size) return "invalid";
  return [start, end];
}

const SAFE_MIME = /^(image|video|audio)\/[a-z0-9.+-]+$|^application\/(pdf|zip|octet-stream)$|^text\/plain$/i;
function safeMime(type: string): string {
  return SAFE_MIME.test(type) ? type : "application/octet-stream";
}

function disposition(name: string): string {
  const ascii = name.replace(/[^\x20-\x7e]/g, "_").replace(/["\\]/g, "_");
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`;
}

async function validateDestination(input: string): Promise<string> {
  if (!isAbsolute(input)) throw new ProtocolError("BAD_REQUEST", "destination must be absolute");
  const dir = resolve(input);
  try {
    await mkdir(dir, { recursive: true });
    const probe = join(dir, `.swiftdrop-probe-${process.pid}`);
    await writeFile(probe, "");
    await rm(probe, { force: true });
    await access(dir);
  } catch {
    throw new ProtocolError("DISK_WRITE", "destination not writable");
  }
  return dir;
}

/** Native Windows folder picker, run as the logged-in user who is sitting at this PC. */
function chooseFolderDialog(current: string): Promise<string | null> {
  if (process.platform !== "win32") return Promise.reject(new ProtocolError("BAD_REQUEST", "folder picker is Windows-only"));
  const script = [
    "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8",
    "Add-Type -AssemblyName System.Windows.Forms",
    "$d = New-Object System.Windows.Forms.FolderBrowserDialog",
    "$d.Description = 'Choose where SwiftDrop saves received files'",
    "$d.UseDescriptionForTitle = $true",
    "$d.ShowNewFolderButton = $true",
    "if (Test-Path -LiteralPath $env:SD_CURRENT) { $d.SelectedPath = $env:SD_CURRENT }",
    "$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }",
    "if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($d.SelectedPath) }",
  ].join("; ");
  return new Promise((resolvePromise) => {
    const child = spawn("powershell.exe", ["-NoProfile", "-STA", "-NonInteractive", "-Command", script], {
      env: { ...process.env, SD_CURRENT: current },
      windowsHide: false,
    });
    let out = "";
    child.stdout.on("data", (d: Buffer) => (out += d.toString("utf8")));
    const timer = setTimeout(() => child.kill(), 5 * 60_000);
    child.on("close", () => {
      clearTimeout(timer);
      resolvePromise(out.trim() || null);
    });
    child.on("error", () => resolvePromise(null));
  });
}

export async function readVersion(): Promise<string> {
  try {
    return (JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8")) as { version: string }).version;
  } catch {
    return VERSION;
  }
}

export type { ServerEvent };
