import { randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";

/**
 * SwiftDrop rendezvous: a tiny pub/sub mailbox for WebRTC signaling between two phones.
 *
 * SIGNALING ONLY. It relays sealed SDP offers/answers (~1 KB, AES-GCM encrypted by the
 * phones with a key this server never sees). It has no way to carry file data: bodies are
 * capped at 4 KiB, a topic keeps at most 16 messages for 10 minutes, and nothing touches
 * disk. File bytes go over the WebRTC DataChannel directly between the phones.
 *
 * Speaks the subset of the ntfy protocol the web app uses, so the app works against this
 * server or ntfy.sh unchanged:
 *   POST /<topic>                       publish (text body)
 *   GET  /<topic>/json?since=all|<id>   stream: one JSON event per line, cached ones first
 */

export interface SignalServerOptions {
  port?: number;
  host?: string;
  ttlMs?: number;
  maxPerTopic?: number;
  maxBody?: number;
  maxTopics?: number;
}

interface Event {
  id: string;
  time: number;
  event: "message";
  topic: string;
  message: string;
}

const TOPIC = /^[A-Za-z0-9_-]{1,64}$/;

export function createSignalServer(opts: SignalServerOptions = {}): Server {
  const ttl = opts.ttlMs ?? 10 * 60_000;
  const maxPerTopic = opts.maxPerTopic ?? 16;
  const maxBody = opts.maxBody ?? 4096;
  const maxTopics = opts.maxTopics ?? 10_000;
  const topics = new Map<string, { events: Event[]; subs: Set<ServerResponse>; touched: number }>();

  const sweep = setInterval(() => {
    const cutoff = Date.now() - ttl;
    for (const [k, t] of topics) {
      t.events = t.events.filter((e) => e.time * 1000 >= cutoff);
      if (!t.events.length && !t.subs.size && t.touched < cutoff) topics.delete(k);
    }
  }, 30_000);
  sweep.unref();

  const topic = (name: string) => {
    let t = topics.get(name);
    if (!t) {
      if (topics.size >= maxTopics) return null;
      t = { events: [], subs: new Set(), touched: Date.now() };
      topics.set(name, t);
    }
    t.touched = Date.now();
    return t;
  };

  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    res.setHeader("access-control-allow-origin", "*");
    res.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
    res.setHeader("access-control-allow-headers", "*");
    res.setHeader("cache-control", "no-store");
    if (req.method === "OPTIONS") return void res.writeHead(204).end();
    const url = new URL(req.url ?? "/", "http://x");
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length === 0 && req.method === "GET") return void res.writeHead(200, { "content-type": "text/plain" }).end("swiftdrop signal: SDP only, never files\n");
    const name = parts[0] ?? "";
    if (!TOPIC.test(name)) return void res.writeHead(400).end();

    if (req.method === "POST" && parts.length === 1) {
      let size = 0;
      const chunks: Buffer[] = [];
      req.on("data", (c: Buffer) => {
        size += c.length;
        if (size > maxBody) {
          res.writeHead(413).end();
          req.destroy();
          return;
        }
        chunks.push(c);
      });
      req.on("end", () => {
        if (res.headersSent) return;
        const t = topic(name);
        if (!t) return void res.writeHead(503).end();
        const ev: Event = { id: randomBytes(9).toString("base64url"), time: Math.floor(Date.now() / 1000), event: "message", topic: name, message: Buffer.concat(chunks).toString("utf8") };
        t.events.push(ev);
        if (t.events.length > maxPerTopic) t.events.shift();
        const line = `${JSON.stringify(ev)}\n`;
        for (const s of t.subs) s.write(line);
        res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(ev));
      });
      return;
    }

    if (req.method === "GET" && parts.length === 2 && parts[1] === "json") {
      const t = topic(name);
      if (!t) return void res.writeHead(503).end();
      res.writeHead(200, { "content-type": "application/x-ndjson; charset=utf-8", "x-accel-buffering": "no" });
      res.write(`${JSON.stringify({ id: "open", time: Math.floor(Date.now() / 1000), event: "open", topic: name })}\n`);
      const since = url.searchParams.get("since") ?? "";
      let from = 0;
      if (since === "all") from = 0;
      else if (since) {
        const i = t.events.findIndex((e) => e.id === since);
        from = i >= 0 ? i + 1 : t.events.length;
      } else from = t.events.length;
      for (const e of t.events.slice(from)) res.write(`${JSON.stringify(e)}\n`);
      t.subs.add(res);
      const keep = setInterval(() => res.write(`${JSON.stringify({ id: "ka", time: Math.floor(Date.now() / 1000), event: "keepalive", topic: name })}\n`), 25_000);
      req.on("close", () => {
        clearInterval(keep);
        t.subs.delete(res);
      });
      return;
    }

    res.writeHead(404).end();
  });
  server.on("close", () => clearInterval(sweep));
  return server;
}
