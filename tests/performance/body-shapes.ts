/**
 * Request-body shape vs upload speed, Node (undici) sender -> real server sink.
 * The browser counterpart is browser-bench.ts; results differ per runtime, which is the point.
 */
import { startServer, MB, MiB } from "./lab.ts";
const server = await startServer();
const SIZE = 8 * MiB;
const parts512 = Array.from({ length: 512 }, () => new Uint8Array(SIZE / 512).fill(7).buffer);
const flat = new Uint8Array(SIZE).fill(7);
const shapes: Array<[string, () => BodyInit]> = [
  ["Uint8Array (1 part)", () => flat],
  ["Blob of 1 Uint8Array", () => new Blob([flat])],
  ["Blob of 512 ArrayBuffers", () => new Blob(parts512)],
  ["ArrayBuffer", () => flat.buffer],
];
for (const [name, make] of shapes) {
  const times: number[] = [];
  for (let r = 0; r < 12; r++) {
    const body = make();
    const t0 = performance.now();
    const res = await fetch(`${server.base}/api/bench/sink`, { method: "POST", body, headers: { authorization: `Bearer ${server.token}`, "content-type": "application/octet-stream" } });
    await res.arrayBuffer();
    times.push(performance.now() - t0);
  }
  times.sort((a, b) => a - b);
  const med = times[6]!;
  console.log(`${name.padEnd(28)} ${(SIZE / MB / (med / 1000)).toFixed(0).padStart(6)} MB/s  (${med.toFixed(1)} ms / 8 MiB)`);
}
await server.close();
