/**
 * PC -> phone with the native source: time from "picked" to "offer ready" and download
 * throughput straight from the original file. Before this path existed, the same file went
 * through a Chromium upload into the outbox first (~40 MB/s, PERFORMANCE_AUDIT.md §3).
 *
 *   pnpm tsx tests/performance/native-offer-bench.ts [sizeMB=1024]
 */
import { open, rm } from "node:fs/promises";
import { join } from "node:path";
import { cleanup, pairGuest, startServer } from "../integration/helpers.ts";

const sizeMb = Number(process.argv[2] ?? 1024);
const s = await startServer();
try {
  const token = await pairGuest(s);
  const path = join(s.dirs.root, "big.bin");
  const fh = await open(path, "w");
  const chunk = Buffer.alloc(16 << 20, 7);
  for (let i = 0; i < sizeMb / 16; i++) await fh.write(chunk);
  await fh.close();

  let t0 = performance.now();
  const res = await s.hostFetch("/api/host/offers/paths", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ paths: [path] }) });
  const { offer } = (await res.json()) as { offer: { transferId: string; files: Array<{ id: string }> } };
  const readyMs = performance.now() - t0;

  const auth = { authorization: `Bearer ${token}` };
  t0 = performance.now();
  const dl = await fetch(`${s.base}/api/offers/${offer.transferId}/files/${offer.files[0]!.id}`, { headers: auth });
  let n = 0;
  const reader = dl.body!.getReader();
  for (let r = await reader.read(); !r.done; r = await reader.read()) n += r.value.byteLength;
  const s1 = (performance.now() - t0) / 1000;
  console.log(JSON.stringify({ sizeMb, offerReadyMs: Math.round(readyMs), downloadMBps: Math.round(n / 1e6 / s1), bytes: n }));
  await rm(path, { force: true });
} finally {
  await s.stop();
  await cleanup(s);
}
