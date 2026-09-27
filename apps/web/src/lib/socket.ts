import { WS_AUTH_PREFIX, WS_SUBPROTOCOL, type ServerEvent } from "@swiftdrop/protocol";
import { SpeedMeter } from "@swiftdrop/transfer-engine";
import { getToken } from "./api.ts";
import { addRecent } from "./recent.ts";
import { app } from "./store.ts";

/** Speed of transfers we only observe (PC receiving from the phone), from event deltas. */
const remoteMeters = new Map<string, { meter: SpeedMeter; last: number }>();
export function remoteRate(transferId: string): { speed: number; peak: number; average: number } {
  const m = remoteMeters.get(transferId);
  if (!m) return { speed: 0, peak: 0, average: 0 };
  return { speed: m.meter.rate(), peak: m.meter.peak, average: m.meter.average() };
}

type RttListener = (ms: number) => void;
const rttListeners = new Set<RttListener>();
export function onRtt(fn: RttListener) {
  rttListeners.add(fn);
  return () => rttListeners.delete(fn);
}

let ws: WebSocket | null = null;
let retry = 0;
let pingTimer: ReturnType<typeof setInterval> | undefined;
let stopped = false;
let onUnauthorized: (() => void) | null = null;

export function connectEvents(opts: { onUnauthorized: () => void }) {
  onUnauthorized = opts.onUnauthorized;
  stopped = false;
  open();
}

export function disconnectEvents() {
  stopped = true;
  ws?.close();
}

function open() {
  if (stopped) return;
  app.set({ conn: retry === 0 ? "connecting" : "offline" });
  const protocols = [WS_SUBPROTOCOL];
  const token = getToken();
  if (token) protocols.push(WS_AUTH_PREFIX + token);
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  const sock = new WebSocket(`${scheme}://${location.host}/api/events`, protocols);
  ws = sock;
  let opened = false;

  sock.onopen = () => {
    opened = true;
    retry = 0;
    app.set({ conn: "online" });
    clearInterval(pingTimer);
    const ping = () => sock.readyState === sock.OPEN && sock.send(JSON.stringify({ t: "ping", n: performance.now() }));
    ping();
    pingTimer = setInterval(ping, 3000);
  };

  sock.onmessage = (ev) => {
    let e: ServerEvent;
    try {
      e = JSON.parse(String(ev.data)) as ServerEvent;
    } catch {
      return;
    }
    handle(e);
  };

  sock.onclose = (ev) => {
    clearInterval(pingTimer);
    if (ws !== sock) return;
    app.set({ conn: "offline" });
    if (ev.code === 4001) return onUnauthorized?.();
    if (stopped) return;
    // A socket that never opened with a token attached is most likely a revoked pairing.
    if (!opened && retry >= 2) void checkAuth();
    const delay = Math.min(8000, 400 * 2 ** retry++);
    setTimeout(open, delay);
  };
}

async function checkAuth() {
  try {
    const res = await fetch("/api/info", { headers: getToken() ? { authorization: `Bearer ${getToken()}` } : {} });
    if (res.status === 401) onUnauthorized?.();
  } catch {
    /* still offline */
  }
}

function handle(e: ServerEvent) {
  switch (e.t) {
    case "pong": {
      const rtt = performance.now() - e.n;
      app.set((s) => ({ rtt: s.rtt === null ? rtt : s.rtt * 0.7 + rtt * 0.3 }));
      for (const l of rttListeners) l(rtt);
      return;
    }
    case "devices":
      app.set({ devices: e.devices });
      return;
    case "offers":
      app.set({ offers: e.offers });
      return;
    case "settings":
      app.set({ destination: e.destination });
      return;
    case "join-request":
      app.set((s) => ({ joinRequests: [...s.joinRequests.filter((j) => j.requestId !== e.requestId), e] }));
      return;
    case "join-resolved":
      app.set((s) => ({ joinRequests: s.joinRequests.filter((j) => j.requestId !== e.requestId) }));
      return;
    case "progress": {
      let m = remoteMeters.get(e.transferId);
      if (!m) {
        m = { meter: new SpeedMeter(3000), last: e.bytesDone };
        m.meter.start();
        remoteMeters.set(e.transferId, m);
      }
      const delta = e.bytesDone - m.last;
      if (delta > 0) m.meter.add(delta);
      m.last = e.bytesDone;
      if (e.state !== "active") m.meter.stop();
      if (e.state === "complete" && e.direction === "to-host") {
        addRecent({
          id: e.transferId,
          label: e.label || "Files",
          flow: "to-pc",
          files: e.filesTotal,
          bytes: e.bytesTotal,
          seconds: m.meter.activeSeconds,
          at: Date.now(),
          kinds: { images: 0, videos: 0, other: e.filesTotal },
        });
      }
      app.set((s) => ({ remote: { ...s.remote, [e.transferId]: { ...e, at: Date.now() } } }));
      return;
    }
    default:
      return;
  }
}
