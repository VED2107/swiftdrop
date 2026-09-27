/**
 * Disk benchmark, network excluded: what the receiver's storage can absorb.
 *
 *   pnpm bench:disk [--dir=D:\somewhere]      default: a temp dir on the system drive
 *
 * Measures the operations the receiver actually performs:
 *   - sequential writes (1 part file, 16 MiB positional writes)          -> large-file ceiling
 *   - parallel positional writes into one part file (4 writers)           -> parallel-range path
 *   - small-file create+write+close at several parallelism levels        -> batch path ceiling
 *   - the same, spread over several folders                              -> is it per-directory?
 * If the network delivers more than these numbers, the disk is the bottleneck and backpressure
 * (x-sd-load) must slow the sender instead of buffering.
 */
import { mkdir, mkdtemp, open, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gitRev, MB, MiB, pct } from "./lab.ts";

const dirArg = process.argv.find((a) => a.startsWith("--dir="))?.split("=")[1];
const base = await mkdtemp(join(dirArg ?? tmpdir(), "sd-disk-"));
const data = new Uint8Array(16 * MiB);
for (let i = 0; i < data.length; i++) data[i] = (i * 2654435761) >>> 24;

async function sequential(totalMiB: number) {
  const fh = await open(join(base, "seq.part"), "w");
  const t0 = performance.now();
  for (let off = 0; off < totalMiB * MiB; off += data.length) await fh.write(data, 0, data.length, off);
  await fh.sync();
  const secs = (performance.now() - t0) / 1000;
  await fh.close();
  return (totalMiB * MiB) / secs / MB;
}

async function parallelRanges(totalMiB: number, writers: number) {
  const fh = await open(join(base, "par.part"), "w");
  let next = 0;
  const t0 = performance.now();
  await Promise.all(
    Array.from({ length: writers }, async () => {
      for (;;) {
        const off = next;
        next += data.length;
        if (off >= totalMiB * MiB) return;
        await fh.write(data, 0, data.length, off);
      }
    }),
  );
  await fh.sync();
  const secs = (performance.now() - t0) / 1000;
  await fh.close();
  return (totalMiB * MiB) / secs / MB;
}

async function smallFiles(count: number, size: number, parallel: number, dirs: number) {
  const root = await mkdtemp(join(base, "small-"));
  for (let d = 0; d < dirs; d++) await mkdir(join(root, `d${d}`));
  const lat: number[] = [];
  let i = 0;
  const t0 = performance.now();
  await Promise.all(
    Array.from({ length: parallel }, async () => {
      while (i < count) {
        const k = i++;
        const a = performance.now();
        const fh = await open(join(root, `d${k % dirs}`, `IMG_${k}.jpg`), "wx");
        await fh.write(data, 0, size, 0);
        await fh.close();
        lat.push(performance.now() - a);
      }
    }),
  );
  const secs = (performance.now() - t0) / 1000;
  await rm(root, { recursive: true, force: true });
  return { filesPerSec: Math.round(count / secs), MBs: +((count * size) / secs / MB).toFixed(1), p50: +pct(lat, 50).toFixed(2), p95: +pct(lat, 95).toFixed(2) };
}

console.log(`\nSwiftDrop disk benchmark (${gitRev()}) at ${base}\n`);
const rows: Array<Record<string, string | number>> = [];
const seq = await sequential(1024);
rows.push({ test: "sequential 1 GiB, 16 MiB writes + fsync", MBs: +seq.toFixed(0) });
const par = await parallelRanges(1024, 4);
rows.push({ test: "4 parallel range writers, 1 GiB + fsync", MBs: +par.toFixed(0) });
for (const parallel of [1, 4, 16, 64]) {
  const r = await smallFiles(2000, 50_000, parallel, 1);
  rows.push({ test: `2,000 x 50 KB, ${parallel} in parallel, 1 folder`, ...r });
}
for (const dirs of [4, 16]) {
  const r = await smallFiles(2000, 50_000, 16, dirs);
  rows.push({ test: `2,000 x 50 KB, 16 in parallel, ${dirs} folders`, ...r });
}
const tiny = await smallFiles(2000, 10_000, 16, 1);
rows.push({ test: "2,000 x 10 KB, 16 in parallel, 1 folder", ...tiny });
console.table(rows);
await rm(base, { recursive: true, force: true });
