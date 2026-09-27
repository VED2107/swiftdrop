import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createLogger, setLogLevel } from "@swiftdrop/shared";
import { createApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { lanAddresses } from "./net.ts";

/** Boots the local server. Shared by `pnpm start` and the packaged SwiftDrop.exe. */
export async function start(opts: { packaged?: boolean } = {}): Promise<void> {
  const config = loadConfig();
  setLogLevel(config.logLevel);
  const log = createLogger("swiftdrop");
  const app = createApp(config, log);
  const local = `http://localhost:${config.port}`;

  try {
    const port = await app.listen();
    const url = `http://localhost:${port}`;
    const lan = lanAddresses().filter((a) => !a.virtual);
    console.log("");
    console.log("  SwiftDrop is running.");
    console.log(`  Open on this PC:   ${url}`);
    for (const a of lan) console.log(`  Phone reaches it:  http://${a.address}:${port}   (${a.interfaceName})`);
    console.log(`  Saving files to:   ${config.destination}`);
    console.log("");
    if (!lan.length) log.warn("No Wi-Fi/Ethernet address found. Connect this PC to the same network as the phone (or to its hotspot).");
    if (process.platform === "win32") {
      console.log(`  If the phone can't connect: allow ${opts.packaged ? "SwiftDrop" : "Node.js"} through Windows Firewall on Private networks`);
      console.log("  (Windows asks on first run).");
      if (opts.packaged) console.log("  Keep this window open while you transfer. Close it to stop SwiftDrop.");
      console.log("");
    }
    if (config.openBrowser) openBrowser(url);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "EADDRINUSE") {
      // Double-clicked twice: the first instance is serving — just show it.
      if (await alreadyRunning(local)) {
        console.log(`  SwiftDrop is already running at ${local}. Opening it.`);
        openBrowser(local);
        process.exit(0);
      }
      log.error(`Port ${config.port} is used by another program. Set SWIFTDROP_PORT to use another port.`);
    } else {
      log.error("failed to start", err);
    }
    process.exit(1);
  }

  let closing = false;
  const shutdown = async () => {
    if (closing) return;
    closing = true;
    log.info("shutting down, saving transfer state…");
    const force = setTimeout(() => process.exit(0), 3000);
    force.unref();
    await app.close().catch(() => undefined);
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

async function alreadyRunning(base: string): Promise<boolean> {
  try {
    const res = await fetch(`${base}/api/info`, { signal: AbortSignal.timeout(1500) });
    const body = (await res.json()) as { version?: string };
    return typeof body.version === "string";
  } catch {
    return false;
  }
}

/**
 * Opens the UI. On Windows it gets its own app window (Edge or Chrome in --app mode with a
 * dedicated profile: no tabs, no address bar, its own taskbar entry) so SwiftDrop feels like
 * a desktop app rather than a web page. Falls back to the default browser.
 * SWIFTDROP_OPEN=browser forces a normal browser tab.
 */
function openBrowser(url: string) {
  if (process.platform === "win32" && process.env.SWIFTDROP_OPEN !== "browser") {
    const exe = appBrowser();
    if (exe) {
      const profile = join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local"), "SwiftDrop", "window");
      const child = spawn(exe, [`--app=${url}`, `--user-data-dir=${profile}`, "--window-size=1280,860", "--no-first-run", "--no-default-browser-check"], {
        detached: true,
        stdio: "ignore",
      });
      child.on("error", () => openDefault(url));
      child.unref();
      return;
    }
  }
  openDefault(url);
}

function openDefault(url: string) {
  const cmd = process.platform === "win32" ? "cmd" : process.platform === "darwin" ? "open" : "xdg-open";
  const args = process.platform === "win32" ? ["/c", "start", "", url] : [url];
  spawn(cmd, args, { detached: true, stdio: "ignore", windowsHide: true }).unref();
}

function appBrowser(): string | null {
  const pf = process.env.ProgramFiles ?? "C:\\Program Files";
  const pf86 = process.env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)";
  const local = process.env.LOCALAPPDATA ?? "";
  const candidates = [
    join(pf86, "Microsoft", "Edge", "Application", "msedge.exe"),
    join(pf, "Microsoft", "Edge", "Application", "msedge.exe"),
    join(pf, "Google", "Chrome", "Application", "chrome.exe"),
    join(pf86, "Google", "Chrome", "Application", "chrome.exe"),
    ...(local ? [join(local, "Google", "Chrome", "Application", "chrome.exe")] : []),
  ];
  return candidates.find((c) => existsSync(c)) ?? null;
}
