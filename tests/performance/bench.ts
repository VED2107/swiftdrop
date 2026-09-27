/**
 * Engine benchmark: the real engine (this process) -> the real server (child process) over loopback.
 *
 *   pnpm bench                     A, B, E, F, G, H into the verify-only sink
 *   pnpm bench --disk              receiver writes to disk (tmp dir on the system drive)
 *   pnpm bench --large             adds C (5 GB), D (10 GB) and 50,000 x 10 KB
 *   pnpm bench --only=B,G          run a subset
 *   pnpm bench --sha256            cryptographic block digests instead of xxh64
 *   pnpm bench --sweep             fixed streams x chunk grid on 1 GB (finds the ceiling)
 *   pnpm bench --tag=name          label stored with the results
 *   pnpm bench --check             compare to tests/performance/budget.json, exit 1 on regression
 *
 * Loopback has no Wi-Fi in the way: these numbers are the SOFTWARE ceiling (engine + server +
 * disk), not what a phone gets. Real-LAN numbers come from the in-app bench (/#/bench) and are
 * recorded by hand in PERFORMANCE_REPORT.md with the network they were taken on.
 */
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { formatBytes, setLogLevel } from "@swiftdrop/shared";
import { DESKTOP_CONTROLLER, HttpTransport, TransferJob, type ControllerConfig, type SourceFile } from "@swiftdrop/transfer-engine";
import { diskBlob, gitRev, makeSource, MB, MiB, startServer, type LabServer } from "./lab.ts";

setLogLevel("warn");
const argv = process.argv.slice(2);
const flag = (f: string) => argv.includes(f);
const opt = (k: string) => argv.find((a) => a.startsWith(`--${k}=`))?.split("=")[1];
const toDisk = flag("--disk");
const integrity = flag("--sha256") ? "sha256" : "xxh64";
const only = opt("only")?.split(",");
const tag = opt("tag") ?? "";

const SOURCE_BYTES = 256 * MiB;
const src = await makeSource(SOURCE_BYTES);
let n = 0;
let cursor = 0;
function file(size: number, name: string, dir = "bench"): SourceFile {
  const from = cursor;
  cursor = (cursor + size) % SOURCE_BYTES;
  return { id: `file_${String(++n).padStart(7, "0")}`, name, relDir: dir, size, type: "application/octet-stream", lastModified: Date.now(), blob: diskBlob(src.fh, SOURCE_BYTES, from, from + size) };
}
const many = (count: number, size: number, prefix: string, ext: string) => Array.from({ length: count }, (_, i) => file(size, `${prefix}_${i}.${ext}`));

interface Scenario {
  id: string;
  name: string;
  large?: boolean;
  files: () => SourceFile[];
}
const scenarios: Scenario[] = [
  { id: "A", name: "100 MB file", files: () => [file(100 * MB, "100mb.bin")] },
  { id: "B", name: "1 GB file", files: () => [file(1000 * MB, "1gb.bin")] },
  { id: "C", name: "5 GB file", large: true, files: () => [file(5000 * MB, "5gb.bin")] },
  { id: "D", name: "10 GB file", large: true, files: () => [file(10_000 * MB, "10gb.bin")] },
  { id: "E", name: "1,000 x 10 KB", files: () => many(1000, 10_000, "e", "txt") },
  { id: "F", name: "1,000 x 100 KB", files: () => many(1000, 100_000, "f", "jpg") },
  { id: "G", name: "10,000 x 50 KB", files: () => many(10_000, 50_000, "g", "jpg") },
  { id: "G2", name: "50,000 x 10 KB", large: true, files: () => many(50_000, 10_000, "g2", "txt") },
  {
    id: "H",
    name: "mixed: photos+videos+PDFs",
    files: () => [...many(300, 3 * MB, "IMG", "HEIC"), ...many(8, 60 * MB, "MOV", "MOV"), ...many(150, 400_000, "doc", "pdf")],
  },
];

interface Row {
  id: string;
  scenario: string;
  state: string;
  seconds: number;
  MBs: number;
  filesPerSec: number;
  p50MBs: number;
  p95MBs: number;
  streams: number;
  chunkMiB: number;
  peakInflightMiB: number;
  requests: number;
  prepareMs: number;
  latP50ms: number;
  latP95ms: number;
  retries: number;
  senderCpuPct: number;
  receiverCpuPct: number;
  senderRssMB: number;
  receiverRssMB: number;
  /** % of summed sender stage time */
  sRead: number;
  sHash: number;
  sFrame: number;
  sNet: number;
  sComplete: number;
  /** receiver ms per GB */
  rRecvMsPerGB: number;
  rHashMsPerGB: number;
  rWriteMsPerGB: number;
  rPeakQueueMiB: number;
  rWriteP95ms: number;
}

async function runOne(server: LabServer, sc: Scenario, controller?: ControllerConfig): Promise<Row> {
  const files = sc.files();
  const transport = new HttpTransport({ baseUrl: server.base, token: server.token });
  const job = new TransferJob({ transport, files, direction: "to-host", label: sc.name, integrity, bench: !toDisk, onConflict: "replace", ...(controller ? { controller } : {}) });
  const s0 = await server.stats();
  let senderRss = process.memoryUsage().rss;
  let receiverRss = s0.rss;
  const poll = setInterval(() => {
    senderRss = Math.max(senderRss, process.memoryUsage().rss);
    void server.stats().then((s) => (receiverRss = Math.max(receiverRss, s.rss)), () => undefined);
  }, 250);
  const cpu0 = process.cpuUsage();
  const t0 = performance.now();
  await job.start();
  await Promise.race([job.done, new Promise<void>((r) => job.onChange((j) => j.state === "paused" && r()))]);
  const secs = (performance.now() - t0) / 1000;
  const cpu = process.cpuUsage(cpu0);
  clearInterval(poll);
  const s1 = await server.stats();
  const s = job.snapshot();
  const tm = job.telemetry();
  const st = tm.stages;
  const stageSum = st.readMs + st.hashMs + st.frameMs + st.networkMs + st.completeMs || 1;
  const gb = s.bytesTotal / 1e9 || 1;
  const p0 = s0.pipeline;
  const p1 = s1.pipeline;
  const r = (v: number) => Math.round(v * 10) / 10;
  return {
    id: sc.id,
    scenario: sc.name,
    state: s.state,
    seconds: r(secs),
    MBs: r(s.bytesTotal / secs / MB),
    filesPerSec: Math.round(s.filesTotal / secs),
    p50MBs: r(tm.throughputP50 / MB),
    p95MBs: r(tm.throughputP95 / MB),
    streams: s.streams,
    chunkMiB: s.chunkBytes / MiB,
    peakInflightMiB: r(tm.peakInflightBytes / MiB),
    requests: tm.requests,
    prepareMs: Math.round(tm.prepareMs),
    latP50ms: r(tm.latencyP50),
    latP95ms: r(tm.latencyP95),
    retries: s.retries,
    senderCpuPct: Math.round(((cpu.user + cpu.system) / 1e6 / secs) * 100),
    receiverCpuPct: Math.round(((s1.cpuUserMs + s1.cpuSystemMs - s0.cpuUserMs - s0.cpuSystemMs) / 1000 / secs) * 100),
    senderRssMB: Math.round(senderRss / MB),
    receiverRssMB: Math.round(receiverRss / MB),
    sRead: Math.round((st.readMs / stageSum) * 100),
    sHash: Math.round((st.hashMs / stageSum) * 100),
    sFrame: Math.round((st.frameMs / stageSum) * 100),
    sNet: Math.round((st.networkMs / stageSum) * 100),
    sComplete: Math.round((st.completeMs / stageSum) * 100),
    rRecvMsPerGB: Math.round((p1.recvMs - p0.recvMs) / gb),
    rHashMsPerGB: Math.round((p1.hashMs - p0.hashMs) / gb),
    rWriteMsPerGB: Math.round((p1.writeMs - p0.writeMs) / gb),
    rPeakQueueMiB: r(p1.peakQueueBytes / MiB),
    rWriteP95ms: r(p1.writeLatencyP95),
  };
}

const threadpool = opt("threadpool");
const server = await startServer(threadpool ? { env: { UV_THREADPOOL_SIZE: threadpool } } : {});
const rows: Row[] = [];
console.log(`\nSwiftDrop engine benchmark (${gitRev()}${tag ? `, ${tag}` : ""}) — receiver: ${toDisk ? "disk" : "verify-only sink"}, integrity: ${integrity}\n`);

if (flag("--sweep")) {
  const sc = scenarios.find((s) => s.id === "B")!;
  for (const streams of [1, 2, 3, 4, 6, 8]) {
    for (const blocks of [1, 2, 4, 8, 16]) {
      const cfg: ControllerConfig = { ...DESKTOP_CONTROLLER, minStreams: streams, maxStreams: streams, initialStreams: streams, minBlocks: blocks, maxBlocks: blocks, initialBlocks: blocks, memoryBudget: 1 << 30 };
      const row = await runOne(server, { ...sc, id: `B@${streams}x${blocks}` }, cfg);
      rows.push(row);
      console.log(`  ${streams} streams x ${String(blocks).padStart(2)} MiB  ${String(row.MBs).padStart(7)} MB/s  cpu s${row.senderCpuPct}% r${row.receiverCpuPct}%  lat p50 ${row.latP50ms} ms`);
    }
  }
} else {
  for (const sc of scenarios) {
    if (only ? !only.includes(sc.id) : sc.large && !flag("--large")) continue;
    const row = await runOne(server, sc);
    rows.push(row);
    if (row.state !== "complete") console.log(`  ${sc.name}: ${row.state}`);
    console.log(
      `  ${sc.id.padEnd(3)} ${sc.name.padEnd(26)} ${String(row.MBs).padStart(7)} MB/s  ${String(row.filesPerSec).padStart(6)} files/s  ${row.streams}x${row.chunkMiB}MiB  cpu s${row.senderCpuPct}% r${row.receiverCpuPct}%  rss s${row.senderRssMB} r${row.receiverRssMB} MB  prep ${row.prepareMs}ms  stages r${row.sRead}/h${row.sHash}/f${row.sFrame}/n${row.sNet}/c${row.sComplete}%`,
    );
    if (toDisk) await rm(join(server.dest, "bench"), { recursive: true, force: true });
  }
}

console.log("");
console.table(rows.map(({ id, MBs, filesPerSec, p50MBs, p95MBs, streams, chunkMiB, peakInflightMiB, latP95ms, senderCpuPct, receiverCpuPct, senderRssMB, receiverRssMB, rWriteMsPerGB, rPeakQueueMiB }) => ({ id, MBs, filesPerSec, p50MBs, p95MBs, streams, chunkMiB, peakInflightMiB, latP95ms, senderCpuPct, receiverCpuPct, senderRssMB, receiverRssMB, rWriteMsPerGB, rPeakQueueMiB })));

const outDir = join(import.meta.dirname, "results");
await mkdir(outDir, { recursive: true });
const name = `${flag("--sweep") ? "sweep" : "bench"}-${toDisk ? "disk" : "sink"}-${integrity}${tag ? `-${tag}` : ""}.json`;
await writeFile(join(outDir, name), JSON.stringify({ at: new Date().toISOString(), rev: gitRev(), node: process.version, tag, rows }, null, 2));
console.log(`saved results/${name}  (${formatBytes(SOURCE_BYTES)} source on disk)`);

let failed = false;
if (flag("--check")) {
  const budget = JSON.parse(await readFile(join(import.meta.dirname, "budget.json"), "utf8")) as Record<string, { minMBs?: number; minFilesPerSec?: number; maxReceiverRssMB?: number; maxSenderRssMB?: number }>;
  for (const row of rows) {
    const b = budget[`${toDisk ? "disk" : "sink"}:${row.id}`];
    if (!b) continue;
    const problems: string[] = [];
    if (row.state !== "complete") problems.push(`state ${row.state}`);
    if (b.minMBs && row.MBs < b.minMBs) problems.push(`${row.MBs} MB/s < ${b.minMBs}`);
    if (b.minFilesPerSec && row.filesPerSec < b.minFilesPerSec) problems.push(`${row.filesPerSec} files/s < ${b.minFilesPerSec}`);
    if (b.maxReceiverRssMB && row.receiverRssMB > b.maxReceiverRssMB) problems.push(`receiver RSS ${row.receiverRssMB} MB > ${b.maxReceiverRssMB}`);
    if (b.maxSenderRssMB && row.senderRssMB > b.maxSenderRssMB) problems.push(`sender RSS ${row.senderRssMB} MB > ${b.maxSenderRssMB}`);
    if (problems.length) {
      failed = true;
      console.log(`  BUDGET ${row.id}: ${problems.join(", ")}`);
    }
  }
  console.log(failed ? "performance budget: FAILED" : "performance budget: ok");
}

await server.close();
await src.dispose();
process.exit(failed ? 1 : 0);
