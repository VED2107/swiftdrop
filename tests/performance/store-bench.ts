/**
 * Receiver store in isolation: batch frames straight into TransferStore.writeBatch, no network.
 * Separates "how fast can the store land small files" from "how fast do they arrive".
 *
 *   npx tsx tests/performance/store-bench.ts [--files=10000] [--size=50000] [--concurrency=4]
 */
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bytesToBase64Url, createBlockHasher } from "@swiftdrop/crypto";
import { BLOCK_SIZE, encodeBatchHeader } from "@swiftdrop/protocol";
import { createLogger, setLogLevel } from "@swiftdrop/shared";
import { TransferStore } from "../../apps/server/src/store.ts";

setLogLevel("error");
const opt = (k: string, d: number) => Number(process.argv.find((a) => a.startsWith(`--${k}=`))?.split("=")[1] ?? d);
const FILES = opt("files", 10_000);
const SIZE = opt("size", 50_000);
const CONC = opt("concurrency", 4);
const PER_BATCH = Math.min(512, Math.floor((8 << 20) / SIZE));

const root = await mkdtemp(join(tmpdir(), "sd-store-"));
const store = new TransferStore({
  destination: () => join(root, "dest"),
  outboxDir: join(root, "outbox"),
  maxFileSize: () => 1e13,
  log: createLogger("store"),
  hooks: { progress() {}, completed() {} },
});
const ids = Array.from({ length: FILES }, (_, i) => `file_${String(i).padStart(7, "0")}`);
const t0c = performance.now();
const created = await store.create(
  {
    protocol: 1,
    transferId: "tr_storebench01",
    direction: "to-host",
    label: "store bench",
    integrity: "xxh64",
    onConflict: "keep-both",
    decisions: {},
    bench: false,
    files: ids.map((id, i) => ({ id, name: `IMG_${i}.jpg`, relDir: "bench", size: SIZE, type: "image/jpeg", lastModified: 0 })),
  },
  { id: "d", name: "bench" },
);
const createMs = performance.now() - t0c;
if (!("status" in created)) throw new Error("conflicts");
const t = await store.get("tr_storebench01");
const hasher = await createBlockHasher("xxh64");
const data = new Uint8Array(SIZE);
for (let i = 0; i < SIZE; i++) data[i] = (i * 2654435761) >>> 24;
const hash = bytesToBase64Url(hasher.hashBlocks(data, BLOCK_SIZE));
const frames: Buffer[] = [];
for (let i = 0; i < FILES; i += PER_BATCH) {
  const chunk = ids.slice(i, i + PER_BATCH);
  const header = encodeBatchHeader({ files: chunk.map((id) => ({ id, size: SIZE, hash })) });
  const frame = Buffer.allocUnsafe(header.length + chunk.length * SIZE);
  frame.set(header, 0);
  for (let k = 0; k < chunk.length; k++) frame.set(data, header.length + k * SIZE);
  frames.push(frame);
}
let next = 0;
const t0 = performance.now();
await Promise.all(Array.from({ length: CONC }, async () => {
  while (next < frames.length) await store.writeBatch(t, frames[next++]!);
}));
const secs = (performance.now() - t0) / 1000;
console.log(`store: ${FILES} x ${SIZE} B, ${PER_BATCH}/batch, ${CONC} concurrent batches: ${Math.round(FILES / secs)} files/s, ${((FILES * SIZE) / secs / 1e6).toFixed(1)} MB/s; create() ${createMs.toFixed(0)} ms`);
await store.flushAll();
await rm(root, { recursive: true, force: true });
