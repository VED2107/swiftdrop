import { spawn } from "node:child_process";
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

function openBrowser(url: string) {
  const cmd = process.platform === "win32" ? "cmd" : process.platform === "darwin" ? "open" : "xdg-open";
  const args = process.platform === "win32" ? ["/c", "start", "", url] : [url];
  spawn(cmd, args, { detached: true, stdio: "ignore", windowsHide: true }).unref();
}
