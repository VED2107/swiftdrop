import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomCode, randomToken, safeEqual } from "@swiftdrop/crypto";
import type { DeviceInfo } from "@swiftdrop/protocol";
import { ProtocolError } from "@swiftdrop/protocol";

/**
 * Pairing and device authentication.
 *
 * - The PC shows a pairing token (QR, 128-bit) and a 6-char code (typed fallback).
 *   Both expire after `pairingTtlMs` and rotate after every successful pairing.
 * - A join creates a pending request; nothing is granted until the PC user approves it.
 * - Approved devices get a 256-bit bearer token. We store only its SHA-256.
 * - Code guessing is rate-limited per IP and globally; a 31^6 space plus approval
 *   plus rotation makes blind guessing pointless.
 */

export interface Pairing {
  token: string;
  code: string;
  expiresAt: number;
}

interface JoinRequest {
  id: string;
  deviceName: string;
  /** sha256 of the browser's install id, when it sent one */
  installHash?: string;
  /** a device from this browser is already paired: approving replaces it */
  returning: boolean;
  via: "qr" | "code";
  ip: string;
  createdAt: number;
  status: "pending" | "approved" | "denied";
  deviceToken?: string;
  deviceId?: string;
}

interface Device {
  id: string;
  name: string;
  /** sha256 of the browser's install id: one entry per browser, however often it pairs */
  installHash?: string;
  tokenHash: string;
  pairedAt: number;
  lastSeen: number;
}

const JOIN_TTL_MS = 2 * 60_000;

export class Auth {
  private pairing: Pairing | null = null;
  private readonly joins = new Map<string, JoinRequest>();
  private readonly devices = new Map<string, Device>();
  private readonly byTokenHash = new Map<string, Device>();
  private readonly limiter = new RateLimiter();
  private readonly online = new Map<string, number>();
  readonly secret: Buffer;

  constructor(
    private readonly stateDir: string,
    private readonly pairingTtlMs: number,
    private readonly deviceIdleTtlMs: number,
  ) {
    this.secret = this.loadSecret();
    this.loadDevices();
  }

  currentPairing(): Pairing {
    if (!this.pairing || this.pairing.expiresAt <= Date.now()) this.rotatePairing();
    return this.pairing!;
  }

  rotatePairing(): Pairing {
    this.pairing = { token: randomToken(16), code: randomCode(6), expiresAt: Date.now() + this.pairingTtlMs };
    return this.pairing;
  }

  requestJoin(input: { token?: string | undefined; code?: string | undefined; deviceName: string; installId?: string | undefined }, ip: string): JoinRequest {
    this.limiter.hit(`join:${ip}`, 20, 60_000);
    const p = this.pairing;
    const now = Date.now();
    let via: "qr" | "code";
    if (input.token) {
      if (!p || p.expiresAt <= now || !safeEqual(input.token, p.token)) {
        this.limiter.hit(`fail:${ip}`, 8, 60_000);
        throw new ProtocolError("PAIRING_EXPIRED");
      }
      via = "qr";
    } else if (input.code) {
      this.limiter.hit(`code:${ip}`, 6, 60_000);
      this.limiter.hit("code:*", 30, 60_000);
      const code = input.code.toUpperCase().replace(/[^A-Z0-9]/g, "");
      if (!p || p.expiresAt <= now || !safeEqual(code, p.code)) throw new ProtocolError("PAIRING_EXPIRED");
      via = "code";
    } else {
      throw new ProtocolError("BAD_REQUEST");
    }
    this.gcJoins();
    const name = input.deviceName.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 64) || "Device";
    // Same device asking again (double tap, page reload): reuse its pending request.
    const existing = [...this.joins.values()].find((j) => j.ip === ip && j.deviceName === name && j.status === "pending");
    if (existing) return existing;
    const pendingFromIp = [...this.joins.values()].filter((j) => j.ip === ip && j.status === "pending").length;
    if (pendingFromIp >= 3) throw new ProtocolError("RATE_LIMITED");
    const installHash = input.installId ? sha256(`install:${input.installId}`) : undefined;
    const previous = installHash ? this.byInstall(installHash) : undefined;
    const join: JoinRequest = {
      id: randomToken(12),
      // A returning browser keeps the name it had (including one the user chose).
      deviceName: previous?.name ?? name,
      ...(installHash ? { installHash } : {}),
      returning: Boolean(previous),
      via,
      ip,
      createdAt: now,
      status: "pending",
    };
    this.joins.set(join.id, join);
    return join;
  }

  resolveJoin(id: string, approve: boolean): JoinRequest {
    const join = this.joins.get(id);
    if (!join || join.status !== "pending") throw new ProtocolError("NOT_FOUND");
    if (!approve) {
      join.status = "denied";
      return join;
    }
    const token = randomToken(32);
    const previous = join.installHash ? this.byInstall(join.installHash) : undefined;
    let device: Device;
    if (previous) {
      // Same browser pairing again (cleared token, new QR scan): one entry, fresh token, old one revoked.
      this.byTokenHash.delete(previous.tokenHash);
      previous.tokenHash = sha256(token);
      previous.lastSeen = Date.now();
      device = previous;
    } else {
      device = {
        id: `dv_${randomToken(9)}`,
        name: this.uniqueName(join.deviceName),
        ...(join.installHash ? { installHash: join.installHash } : {}),
        tokenHash: sha256(token),
        pairedAt: Date.now(),
        lastSeen: Date.now(),
      };
    }
    this.devices.set(device.id, device);
    this.byTokenHash.set(device.tokenHash, device);
    join.status = "approved";
    join.deviceToken = token;
    join.deviceId = device.id;
    this.rotatePairing(); // the QR on screen is now spent
    this.saveDevices();
    return join;
  }

  /** Guest polls this; the token is handed over exactly once. */
  pollJoin(id: string): { status: JoinRequest["status"]; token?: string; deviceId?: string } {
    const join = this.joins.get(id);
    if (!join || Date.now() - join.createdAt > JOIN_TTL_MS) throw new ProtocolError("PAIRING_EXPIRED");
    if (join.status === "approved" && join.deviceToken) {
      const out = { status: join.status, token: join.deviceToken, deviceId: join.deviceId! };
      this.joins.delete(id);
      return out;
    }
    if (join.status === "denied") this.joins.delete(id);
    return { status: join.status };
  }

  pendingJoins(): JoinRequest[] {
    this.gcJoins();
    return [...this.joins.values()].filter((j) => j.status === "pending");
  }

  authenticate(bearer: string | undefined): Device | null {
    if (!bearer) return null;
    const device = this.byTokenHash.get(sha256(bearer));
    if (!device) return null;
    const now = Date.now();
    if (now - device.lastSeen > this.deviceIdleTtlMs) {
      this.forget(device.id);
      return null;
    }
    if (now - device.lastSeen > 60_000) {
      device.lastSeen = now;
      this.saveDevices();
    }
    return device;
  }

  /** Names are unique across paired devices (case-insensitive). */
  rename(deviceId: string, raw: string): DeviceInfo {
    const d = this.devices.get(deviceId);
    if (!d) throw new ProtocolError("NOT_FOUND");
    const name = cleanName(raw);
    if (!name) throw new ProtocolError("BAD_REQUEST", "empty name");
    if (this.nameTaken(name, d.id)) throw new ProtocolError("NAME_TAKEN");
    d.name = name;
    this.saveDevices();
    return this.info(d);
  }

  forget(deviceId: string): void {
    const d = this.devices.get(deviceId);
    if (!d) return;
    this.devices.delete(deviceId);
    this.byTokenHash.delete(d.tokenHash);
    this.saveDevices();
  }

  setOnline(deviceId: string, delta: 1 | -1) {
    const n = (this.online.get(deviceId) ?? 0) + delta;
    if (n <= 0) this.online.delete(deviceId);
    else this.online.set(deviceId, n);
  }

  listDevices(): DeviceInfo[] {
    return [...this.devices.values()]
      .sort((a, b) => b.pairedAt - a.pairedAt)
      .map((d) => this.info(d));
  }

  private info(d: Device): DeviceInfo {
    return { id: d.id, name: d.name, online: this.online.has(d.id), pairedAt: d.pairedAt };
  }

  private byInstall(hash: string): Device | undefined {
    for (const d of this.devices.values()) if (d.installHash === hash) return d;
    return undefined;
  }

  private nameTaken(name: string, exceptId?: string): boolean {
    const k = name.toLocaleLowerCase();
    for (const d of this.devices.values()) if (d.id !== exceptId && d.name.toLocaleLowerCase() === k) return true;
    return false;
  }

  /** "iPhone" is taken: "iPhone 2", "iPhone 3", and so on. */
  private uniqueName(base: string): string {
    if (!this.nameTaken(base)) return base;
    for (let n = 2; ; n++) {
      const candidate = `${base.slice(0, 36)} ${n}`;
      if (!this.nameTaken(candidate)) return candidate;
    }
  }

  /** Short-lived capability for plain-navigation downloads (Safari can't add headers). */
  signTicket(scope: string, ttlMs = 15 * 60_000): string {
    const exp = Date.now() + ttlMs;
    const mac = createHmac("sha256", this.secret).update(`${scope}|${exp}`).digest("base64url");
    return `${exp}.${mac}`;
  }

  verifyTicket(scope: string, ticket: string | null): boolean {
    if (!ticket) return false;
    const [expStr, mac] = ticket.split(".");
    const exp = Number(expStr);
    if (!mac || !Number.isFinite(exp) || exp < Date.now()) return false;
    const expected = createHmac("sha256", this.secret).update(`${scope}|${exp}`).digest();
    const got = Buffer.from(mac, "base64url");
    return got.length === expected.length && timingSafeEqual(got, expected);
  }

  checkRate(key: string, max: number, windowMs: number) {
    this.limiter.hit(key, max, windowMs);
  }

  private gcJoins() {
    const now = Date.now();
    for (const [id, j] of this.joins) if (now - j.createdAt > JOIN_TTL_MS) this.joins.delete(id);
  }

  private loadSecret(): Buffer {
    const p = join(this.stateDir, "secret");
    try {
      const b = Buffer.from(readFileSync(p, "utf8").trim(), "base64url");
      if (b.length >= 32) return b;
    } catch {
      /* first run */
    }
    const b = Buffer.from(randomToken(32), "base64url");
    this.ensureDir();
    writeFileSync(p, b.toString("base64url"), { mode: 0o600 });
    return b;
  }

  private loadDevices() {
    try {
      const list = JSON.parse(readFileSync(join(this.stateDir, "devices.json"), "utf8")) as Device[];
      for (const d of list) {
        if (Date.now() - d.lastSeen > this.deviceIdleTtlMs) continue;
        this.devices.set(d.id, d);
        this.byTokenHash.set(d.tokenHash, d);
      }
    } catch {
      /* none yet */
    }
  }

  private saveDevices() {
    this.ensureDir();
    const p = join(this.stateDir, "devices.json");
    writeFileSync(`${p}.tmp`, JSON.stringify([...this.devices.values()], null, 2), { mode: 0o600 });
    renameSync(`${p}.tmp`, p);
  }

  private ensureDir() {
    if (!existsSync(this.stateDir)) mkdirSync(this.stateDir, { recursive: true });
  }
}

function cleanName(s: string): string {
  return s
    .replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 40);
}

function sha256(s: string): string {
  return createHash("sha256").update(s).digest("hex");
}

/** Fixed-window counter; plenty for a LAN signaling surface. */
class RateLimiter {
  private readonly hits = new Map<string, { n: number; resetAt: number }>();

  hit(key: string, max: number, windowMs: number) {
    const now = Date.now();
    let h = this.hits.get(key);
    if (!h || h.resetAt <= now) {
      h = { n: 0, resetAt: now + windowMs };
      this.hits.set(key, h);
      if (this.hits.size > 5000) for (const [k, v] of this.hits) if (v.resetAt <= now) this.hits.delete(k);
    }
    if (++h.n > max) throw new ProtocolError("RATE_LIMITED");
  }
}
