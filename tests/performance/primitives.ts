/**
 * Cost of every primitive on the data path, in isolation (Node side: server + bench sender).
 *
 *   pnpm tsx tests/performance/primitives.ts
 *
 * Each row: bytes processed / wall time, median of several runs. These are the numbers the
 * hotspot map in PERFORMANCE_AUDIT.md is built from.
 */
import { createHash } from "node:crypto";
import { openAsBlob } from "node:fs";
import { mkdtemp, open, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bytesToBase64Url, createBlockHasher } from "@swiftdrop/crypto";

const MiB = 1 << 20;
const SIZE = 16 * MiB;
const RUNS = 9;

const data = new Uint8Array(SIZE);
for (let i = 0; i < SIZE; i += 4) data[i] = (i * 2654435761) >>> 24;
const dir = await mkdtemp(join(tmpdir(), "sd-prim-"));
const path = join(dir, "src.bin");
await writeFile(path, data);
const fileBlob = await openAsBlob(path);

async function measure(name: string, bytes: number, fn: () => unknown | Promise<unknown>) {
  await fn();
  const times: number[] = [];
  for (let r = 0; r < RUNS; r++) {
    const t0 = performance.now();
    await fn();
    times.push(performance.now() - t0);
  }
  times.sort((a, b) => a - b);
  const med = times[Math.floor(RUNS / 2)]!;
  console.log(`${name.padEnd(44)} ${(bytes / 1e6 / (med / 1000)).toFixed(0).padStart(7)} MB/s   ${med.toFixed(2).padStart(7)} ms / ${bytes / MiB} MiB`);
}

const xxh = await createBlockHasher("xxh64");
const sha = await createBlockHasher("sha256");

console.log(`\nNode ${process.version} primitives, ${SIZE / MiB} MiB buffers, median of ${RUNS}\n`);
await measure("file blob slice().arrayBuffer()", SIZE, () => fileBlob.slice(0, SIZE).arrayBuffer());
await measure("fh.read into reused buffer", SIZE, async () => {
  const fh = await open(path, "r");
  const buf = Buffer.allocUnsafe(SIZE);
  await fh.read(buf, 0, SIZE, 0);
  await fh.close();
});
await measure("Uint8Array.slice (memcpy)", SIZE, () => data.slice());
await measure("Buffer.copy into preallocated", SIZE, () => Buffer.from(data.buffer).copy(Buffer.allocUnsafe(SIZE)));
await measure("new Blob([u8])", SIZE, () => new Blob([data]));
await measure("new Blob([u8]).arrayBuffer()", SIZE, () => new Blob([data]).arrayBuffer());
await measure("xxh64 hash-wasm, 1 MiB blocks", SIZE, () => xxh.hashBlocks(data, MiB));
await measure("sha256 hash-wasm, 1 MiB blocks", SIZE, () => sha.hashBlocks(data, MiB));
await measure("sha256 node:crypto (OpenSSL), 1 MiB blocks", SIZE, () => {
  for (let o = 0; o < SIZE; o += MiB) createHash("sha256").update(data.subarray(o, o + MiB)).digest();
});
await measure("base64url of 16 digests (8 B each)", 128, () => bytesToBase64Url(data.subarray(0, 128)));
await measure("JSON.stringify 512-entry batch header", 1, () =>
  JSON.stringify({ files: Array.from({ length: 512 }, (_, i) => ({ id: `file_${i}`, size: 50000, hash: "AAAAAAAAAAA" })) }),
);
{
  const fh = await open(join(dir, "w.bin"), "w");
  await measure("fh.write positional 16 MiB (page cache)", SIZE, () => fh.write(data, 0, SIZE, 0));
  await fh.close();
}
await measure("open(wx)+write 50 KB+close x100 (NTFS)", 100 * 50_000, async () => {
  const sub = await mkdtemp(join(dir, "small-"));
  for (let i = 0; i < 100; i++) {
    const fh = await open(join(sub, `f${i}.jpg`), "wx");
    await fh.write(data, 0, 50_000, 0);
    await fh.close();
  }
});
await rm(dir, { recursive: true, force: true });
