import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import type { IncomingMessage } from "node:http";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { LogLevel } from "@swiftdrop/shared";

export interface ServerConfig {
  port: number;
  bindAddress: string;
  /** Where received files land. Changeable at runtime from the PC. */
  destination: string;
  /** Staging for PC -> iPhone offers. */
  outboxDir: string;
  /** Persistent server state: paired devices, settings, secret. */
  stateDir: string;
  webRoot: string;
  maxFileSize: number;
  pairingTtlMs: number;
  deviceIdleTtlMs: number;
  logLevel: LogLevel;
  openBrowser: boolean;
  /** Override for tests: decides whether a request comes from the PC itself. */
  isHostRequest?: (req: IncomingMessage) => boolean;
}

// In the packaged exe (CommonJS bundle) import.meta.url doesn't exist; the web root comes from env there.
const here = (() => {
  try {
    return dirname(fileURLToPath(import.meta.url));
  } catch {
    return process.cwd();
  }
})();

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServerConfig {
  const stateDir = resolve(env.SWIFTDROP_STATE_DIR ?? join(homedir(), ".swiftdrop"));
  const saved = readSettings(stateDir);
  return {
    port: Number(env.SWIFTDROP_PORT ?? 8787),
    bindAddress: env.SWIFTDROP_BIND ?? "0.0.0.0",
    destination: resolve(env.SWIFTDROP_DEST ?? saved.destination ?? join(homedir(), "Downloads", "SwiftDrop")),
    outboxDir: resolve(env.SWIFTDROP_OUTBOX ?? join(tmpdir(), "swiftdrop-outbox")),
    stateDir,
    webRoot: resolve(env.SWIFTDROP_WEB_ROOT ?? join(here, "..", "..", "web", "dist")),
    maxFileSize: Number(env.SWIFTDROP_MAX_FILE_BYTES ?? saved.maxFileSize ?? 512e9),
    pairingTtlMs: 5 * 60_000,
    deviceIdleTtlMs: 7 * 24 * 3600_000,
    logLevel: (env.SWIFTDROP_LOG as LogLevel | undefined) ?? "info",
    openBrowser: env.SWIFTDROP_NO_OPEN !== "1" && env.NODE_ENV !== "test" && env.SWIFTDROP_E2E !== "1",
    // Test-only: lets a second browser on the same PC play the phone. "localhost" is the PC,
    // "127.0.0.1" is the guest. Never enable on a real network.
    ...(env.SWIFTDROP_E2E === "1"
      ? { isHostRequest: (req: IncomingMessage) => (req.headers.host ?? "").startsWith("localhost:") && isLoopback(req.socket.remoteAddress) }
      : {}),
  };
}

function isLoopback(addr: string | undefined) {
  return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
}

interface SavedSettings {
  destination?: string;
  maxFileSize?: number;
}

function settingsPath(stateDir: string) {
  return join(stateDir, "settings.json");
}

function readSettings(stateDir: string): SavedSettings {
  try {
    return JSON.parse(readFileSync(settingsPath(stateDir), "utf8")) as SavedSettings;
  } catch {
    return {};
  }
}

export function saveSettings(config: ServerConfig): void {
  if (!existsSync(config.stateDir)) mkdirSync(config.stateDir, { recursive: true });
  writeFileSync(settingsPath(config.stateDir), JSON.stringify({ destination: config.destination, maxFileSize: config.maxFileSize }, null, 2));
}
