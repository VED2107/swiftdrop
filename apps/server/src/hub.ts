import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import { WS_AUTH_PREFIX, WS_SUBPROTOCOL, type ServerEvent } from "@swiftdrop/protocol";

interface Client {
  ws: WebSocket;
  role: "host" | "guest";
  deviceId: string | null;
}

/**
 * Event fan-out over WebSocket. Control-plane only: no file bytes ever go through here.
 * Auth rides in Sec-WebSocket-Protocol ("swiftdrop.v1", "auth.<token>") because browsers
 * can't set headers on WebSocket requests and tokens don't belong in URLs.
 */
export class Hub {
  private readonly wss = new WebSocketServer({ noServer: true, maxPayload: 4096, perMessageDeflate: false });
  private readonly clients = new Set<Client>();

  constructor(
    private readonly authorize: (req: IncomingMessage, token: string | undefined) => { role: "host" | "guest"; deviceId: string | null } | null,
    private readonly onConnect: (c: { role: "host" | "guest"; deviceId: string | null }, send: (e: ServerEvent) => void) => void,
    private readonly onPresence: (deviceId: string, delta: 1 | -1) => void,
  ) {
    this.wss.on("headers", () => undefined);
  }

  upgrade(req: IncomingMessage, socket: Duplex, head: Buffer) {
    const protocols = String(req.headers["sec-websocket-protocol"] ?? "")
      .split(",")
      .map((s) => s.trim());
    if (!protocols.includes(WS_SUBPROTOCOL)) return reject(socket, 400);
    const token = protocols.find((p) => p.startsWith(WS_AUTH_PREFIX))?.slice(WS_AUTH_PREFIX.length);
    const who = this.authorize(req, token);
    if (!who) return reject(socket, 401);
    this.wss.handleUpgrade(req, socket, head, (ws) => {
      const client: Client = { ws, ...who };
      this.clients.add(client);
      if (client.deviceId) this.onPresence(client.deviceId, 1);
      const send = (e: ServerEvent) => ws.readyState === ws.OPEN && ws.send(JSON.stringify(e));
      send({ t: "hello", role: who.role, deviceId: who.deviceId });
      this.onConnect(who, send);
      ws.on("message", (raw) => {
        // Only app-level ping: lets the UI measure RTT on a connection that isn't queued behind uploads.
        try {
          const msg = JSON.parse(String(raw)) as { t?: string; n?: number };
          if (msg.t === "ping" && typeof msg.n === "number") send({ t: "pong", n: msg.n });
        } catch {
          /* ignore junk */
        }
      });
      ws.on("close", () => {
        this.clients.delete(client);
        if (client.deviceId) this.onPresence(client.deviceId, -1);
      });
    });
  }

  toHosts(e: ServerEvent) {
    this.broadcast(e, (c) => c.role === "host");
  }

  toGuests(e: ServerEvent) {
    this.broadcast(e, (c) => c.role === "guest");
  }

  toDevice(deviceId: string, e: ServerEvent) {
    this.broadcast(e, (c) => c.deviceId === deviceId);
  }

  toAll(e: ServerEvent) {
    this.broadcast(e, () => true);
  }

  disconnectDevice(deviceId: string) {
    for (const c of this.clients) if (c.deviceId === deviceId) c.ws.close(4001, "forgotten");
  }

  close() {
    for (const c of this.clients) c.ws.terminate();
    this.wss.close();
  }

  private broadcast(e: ServerEvent, filter: (c: Client) => boolean) {
    const payload = JSON.stringify(e);
    for (const c of this.clients) if (filter(c) && c.ws.readyState === c.ws.OPEN) c.ws.send(payload);
  }
}

function reject(socket: Duplex, status: number) {
  socket.write(`HTTP/1.1 ${status} ${status === 401 ? "Unauthorized" : "Bad Request"}\r\nConnection: close\r\n\r\n`);
  socket.destroy();
}
