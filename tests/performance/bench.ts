/**
 * Loopback benchmark: the real engine against the real server, same process.
 *
 *   pnpm bench                 # 100 MB, 1 GB, 1,000 and 10,000 small files
 *   pnpm bench --large         # adds 5 GB and 10 GB
 *   pnpm bench --disk          # write to disk instead of the verify-only sink
 *   pnpm bench --sha256        # cryptographic block digests instead of xxh64
 *
 * Loopback has no Wi-Fi in the way, so these numbers are the software ceiling:
 * what the engine + server can push when the network is not the bottleneck.
 */
import { openAsBlob } from "node:fs";
import { mkdir, mkdtemp, open, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BLOCK_SIZE } from "@swiftdrop/protocol";
import { formatBytes, formatDuration, setLogLevel } from "@swiftdrop/shared";
import { HttpTransport, TransferJob, type SourceFile } from "@swiftdrop/transfer-engine";
import { createApp } from "../../apps/server/src/app.ts";

setLogLevel("warn");
const args = new Set(process.argv.slice(2));
const toDisk = args.has("--disk");
const integrity = args.has("--sha256") ? "sha256" : "xxh64";

interface Scenario {
  name: string;
  files: () => SourceFile[];
}

// Inputs are slices of one file-backed Blob, like a browser File: nothing is held in RAM,
// so the RSS column measures the engine + server, not the test data.
const SOURCE_BYTES = 1024 * BLOCK_SIZE;
const sourceDir = await mkdtemp(join(tmpdir(), "swiftdrop-src-"));
const sourcePath = join(sourceDir, "source.bin");
{
  const fh = await open(sourcePath, "w");
  const chunk = new Uint8Array(BLOCK_SIZE);
  for (let b = 0; b < SOURCE_BYTES / BLOCK_SIZE; b++) {
    for (let i = 0; i < chunk.length; i += 4) chunk[i] = (b * 131 + i * 2654435761) >>> 24;
    await fh.write(chunk);
  }
  await fh.close();
}
const sourceBlob = await openAsBlob(sourcePath);

let n = 0;
let cursor = 0;
function file(size: number, name: string): SourceFile {
  const parts: Blob[] = [];
  for (let left = size; left > 0; ) {
    if (cursor >= SOURCE_BYTES) cursor = 0;
    const take = Math.min(left, SOURCE_BYTES - cursor);
    parts.push(sourceBlob.slice(cursor, cursor + take));
    cursor += take;
    left -= take;
  }
  return { id: `file_${String(++n).padStart(7, "0")}`, name, relDir: "bench", size, type: "application/octet-stream", lastModified: Date.now(), blob: parts.length === 1 ? parts[0]! : new Blob(parts) };
}

const MB = 1e6;
const scenarios: Scenario[] = [
  { name: "100 MB file", files: () => [file(100 * MB, "100mb.bin")] },
  { name: "1 GB file", files: () => [file(1000 * MB, "1gb.bin")] },
  { name: "1,000 photos (3 MB)", files: () => Array.from({ length: 1000 }, (_, i) => file(3 * MB, `IMG_${i}.HEIC`)) },
  { name: "1,000 small (200 KB)", files: () => Array.from({ length: 1000 }, (_, i) => file(200_000, `s_${i}.jpg`)) },
  { name: "10,000 small (50 KB)", files: () => Array.from({ length: 10_000 }, (_, i) => file(50_000, `t_${i}.jpg`)) },
];
if (args.has("--large")) {
  scenarios.push({ name: "5 GB file", files: () => [file(5000 * MB, "5gb.bin")] });
  scenarios.push({ name: "10 GB file", files: () => [file(10_000 * MB, "10gb.bin")] });
}

const root = await mkdtemp(join(tmpdir(), "swiftdrop-bench-"));
const app = createApp({
  port: 0,
  bindAddress: "127.0.0.1",
  destination: join(root, "dest"),
  outboxDir: join(root, "outbox"),
  stateDir: join(root, "state"),
  webRoot: join(root, "none"),
  maxFileSize: 1e13,
  pairingTtlMs: 60_000,
  deviceIdleTtlMs: 3600_000,
  logLevel: "warn",
  openBrowser: false,
  isHostRequest: (req) => req.headers["x-bench-host"] === "1",
});
const port = await app.listen();
const base = `http://127.0.0.1:${port}`;
const token = await pair();
const transport = new HttpTransport({ baseUrl: base, token });

async function pair(): Promise<string> {
  const host = { "x-bench-host": "1", "content-type": "application/json" };
  const { code } = (await (await fetch(`${base}/api/host/pairing`, { headers: host })).json()) as { code: string };
  const { requestId } = (await (
    await fetch(`${base}/api/join`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ code, deviceName: "bench" }) })
  ).json()) as { requestId: string };
  await fetch(`${base}/api/host/joins/${requestId}`, { method: "POST", headers: host, body: JSON.stringify({ approve: true }) });
  return ((await (await fetch(`${base}/api/join/${requestId}`)).json()) as { token: string }).token;
}

const rows: Array<Record<string, string | number>> = [];
console.log(`\nSwiftDrop loopback benchmark — sink: ${toDisk ? "disk" : "verify-only"}, integrity: ${integrity}\n`);

for (const sc of scenarios) {
  const files = sc.files();
  const cpu0 = process.cpuUsage();
  let peakRss = process.memoryUsage().rss;
  const job = new TransferJob({ transport, files, direction: "to-host", label: sc.name, integrity, bench: !toDisk, onConflict: "replace" });
  const t0 = performance.now();
  let peak = 0;
  const mem = setInterval(() => {
    peakRss = Math.max(peakRss, process.memoryUsage().rss);
    peak = Math.max(peak, job.snapshot().peak);
  }, 250);
  await job.start();
  await Promise.race([job.done, new Promise<void>((r) => job.onChange((j) => j.state === "paused" && r()))]);
  clearInterval(mem);
  const secs = (performance.now() - t0) / 1000;
  const cpu = process.cpuUsage(cpu0);
  const s = job.snapshot();
  const row = {
    scenario: sc.name,
    state: s.state,
    avgMBs: +(s.bytesTotal / secs / MB).toFixed(1),
    peakMBs: +(Math.max(peak, s.peak) / MB).toFixed(1),
    duration: formatDuration(secs),
    filesPerSec: Math.round(s.filesTotal / secs),
    streams: s.streams,
    chunk: formatBytes(s.chunkBytes),
    cpuPct: +(((cpu.user + cpu.system) / 1e6 / secs) * 100).toFixed(0),
    peakRss: formatBytes(peakRss),
    retries: s.retries,
    chunkFailures: s.chunkFailures,
  };
  rows.push(row);
  if (s.state !== "complete") console.log(`  ${sc.name}: ${s.state} ${s.errorCode ?? ""}`);
  console.log(`  ${sc.name.padEnd(22)} ${String(row.avgMBs).padStart(7)} MB/s avg  ${String(row.peakMBs).padStart(7)} peak  ${row.duration}  ${row.streams}×${row.chunk}  cpu ${row.cpuPct}%  rss ${row.peakRss}`);
  if (toDisk) await rm(join(root, "dest", "bench"), { recursive: true, force: true });
}

console.log("");
console.table(rows);
const outDir = join(import.meta.dirname, "results");
await mkdir(outDir, { recursive: true });
await writeFile(join(outDir, `bench-${toDisk ? "disk" : "sink"}-${integrity}.json`), JSON.stringify({ at: new Date().toISOString(), node: process.version, rows }, null, 2));
await app.close();
await rm(root, { recursive: true, force: true });
await rm(sourceDir, { recursive: true, force: true });
