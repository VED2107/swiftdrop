import { spawn } from "node:child_process";
import { createLogger, setLogLevel } from "@swiftdrop/shared";
import { createApp } from "./app.ts";
import { loadConfig } from "./config.ts";
import { lanAddresses } from "./net.ts";

const config = loadConfig();
setLogLevel(config.logLevel);
const log = createLogger("swiftdrop");
const app = createApp(config, log);

try {
  const port = await app.listen();
  const local = `http://localhost:${port}`;
  const lan = lanAddresses().filter((a) => !a.virtual);
  console.log("");
  console.log("  SwiftDrop is running.");
  console.log(`  Open on this PC:   ${local}`);
  for (const a of lan) console.log(`  Phone reaches it:  http://${a.address}:${port}   (${a.interfaceName})`);
  console.log(`  Saving files to:   ${config.destination}`);
  console.log("");
  if (!lan.length) log.warn("No Wi-Fi/Ethernet address found. Connect this PC to the same network as the phone (or to its hotspot).");
  if (process.platform === "win32") {
    console.log("  If the phone can't connect: allow Node.js through Windows Firewall on Private networks");
    console.log("  (Windows asks on first run), or run scripts/allow-firewall.ps1 as administrator.");
    console.log("");
  }
  if (config.openBrowser) openBrowser(local);
} catch (err) {
  if ((err as NodeJS.ErrnoException).code === "EADDRINUSE") {
    log.error(`Port ${config.port} is busy. Is SwiftDrop already running? Set SWIFTDROP_PORT to use another port.`);
  } else {
    log.error("failed to start", err);
  }
  process.exit(1);
}

let closing = false;
async function shutdown() {
  if (closing) return;
  closing = true;
  log.info("shutting down, saving transfer state…");
  const force = setTimeout(() => process.exit(0), 3000);
  force.unref();
  await app.close().catch(() => undefined);
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

function openBrowser(url: string) {
  const cmd = process.platform === "win32" ? "cmd" : process.platform === "darwin" ? "open" : "xdg-open";
  const args = process.platform === "win32" ? ["/c", "start", "", url] : [url];
  spawn(cmd, args, { detached: true, stdio: "ignore" }).unref();
}
