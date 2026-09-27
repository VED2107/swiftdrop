/**
 * Browser benchmark: real Chromium, real File objects from disk, real engine, real server.
 *
 *   pnpm bench:browser [--headed] [--quick] [--tag=name]
 *
 * 1. primitives   what File reads, hashing and Blob building cost in this browser
 * 2. body shapes  upload speed per request-body type (the Chromium fetch path question)
 * 3. parallelism  aggregate upload speed vs concurrent requests (per-host connection cap)
 * 4. engine       full TransferJob runs from the page into the server sink
 *
 * Safari/iOS cannot be driven from here; the in-app bench (/#/bench) runs the engine part on a phone.
 */
import { build } from "esbuild";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { chromium } from "@playwright/test";
import { gitRev, makeSource, MiB, startServer } from "./lab.ts";

/* eslint-disable @typescript-eslint/no-explicit-any */
const argv = process.argv.slice(2);
const quick = argv.includes("--quick");
const tag = argv.find((a) => a.startsWith("--tag="))?.split("=")[1] ?? "";
const bundle = await build({ entryPoints: [join(import.meta.dirname, "browser/entry.ts")], bundle: true, write: false, format: "iife", platform: "browser", target: "es2022" });
const script = bundle.outputFiles[0]!.text;

const server = await startServer();
const src = await makeSource((quick ? 256 : 1024) * MiB);

const browser = await chromium.launch({ headless: !argv.includes("--headed") });
const page = await browser.newPage();
await page.route(`${server.base}/__bench`, (route) =>
  route.fulfill({ contentType: "text/html", body: `<!doctype html><meta charset=utf-8><input type=file id=f><script>var __name = (f) => f;</script><script>${script}</script>` }),
);
await page.goto(`${server.base}/__bench`);
await page.setInputFiles("#f", src.path);
const ua = await page.evaluate(() => navigator.userAgent.match(/(Headless)?Chrome\/[\d.]+/)?.[0] ?? navigator.userAgent);
console.log(`\nSwiftDrop browser benchmark (${gitRev()}) — ${ua}\n`);

const results = await page.evaluate(
  async ({ base, token, quick }) => {
    const MiB = 1 << 20;
    const file = (document.getElementById("f") as HTMLInputElement).files![0]!;
    const sd = (globalThis as any).sd;
    const out: Record<string, unknown> = {};
    const median = (a: number[]) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)]!;
    const mbs = (bytes: number, ms: number) => Math.round(bytes / 1e6 / (ms / 1000));
    async function timeIt(runs: number, fn: (i: number) => unknown) {
      const t: number[] = [];
      await fn(0);
      for (let i = 0; i < runs; i++) {
        const a = performance.now();
        await fn(i + 1);
        t.push(performance.now() - a);
      }
      return median(t);
    }

    // 1. primitives
    const CH = 16 * MiB;
    const offs = (i: number, len: number) => (i * len) % (file.size - len);
    const prim: Record<string, number> = {};
    prim["File.slice(16 MiB).arrayBuffer()"] = mbs(CH, await timeIt(9, (i) => file.slice(offs(i, CH), offs(i, CH) + CH).arrayBuffer()));
    const buf = new Uint8Array(await file.slice(0, CH).arrayBuffer());
    const xxh = await sd.createBlockHasher("xxh64");
    const sha = await sd.createBlockHasher("sha256");
    prim["xxh64 (wasm), 1 MiB blocks"] = mbs(CH, await timeIt(9, () => xxh.hashBlocks(buf, MiB)));
    prim["sha256 (wasm), 1 MiB blocks"] = mbs(CH, await timeIt(5, () => sha.hashBlocks(buf, MiB)));
    prim["new Blob([u8 16 MiB])"] = mbs(CH, await timeIt(9, () => new Blob([buf])));
    const small = Array.from({ length: 160 }, (_, i) => file.slice(i * 100_000, i * 100_000 + 50_000));
    prim["160 x 50 KB slices -> arrayBuffer, parallel"] = mbs(160 * 50_000, await timeIt(9, () => Promise.all(small.map((b) => b.arrayBuffer()))));
    prim["1 x 8 MB slice -> arrayBuffer"] = mbs(160 * 50_000, await timeIt(9, () => file.slice(0, 160 * 50_000).arrayBuffer()));
    out.primitives = prim;

    // 2. body shapes, one request at a time, 8 MiB
    const auth = { authorization: `Bearer ${token}`, "content-type": "application/octet-stream" };
    const post = (body: BodyInit, extra: RequestInit = {}) =>
      fetch(`${base}/api/bench/sink`, { method: "POST", body, headers: auth, ...extra }).then((r) => {
        if (!r.ok) throw new Error(String(r.status));
      });
    const S = 8 * MiB;
    const flat = new Uint8Array(await file.slice(0, S).arrayBuffer());
    const parts = Array.from({ length: 167 }, (_, i) => flat.slice(i * 50_000, (i + 1) * 50_000).buffer);
    const shapes: Record<string, number | string> = {};
    const shape = async (name: string, make: (i: number) => BodyInit | Promise<BodyInit>, extra?: RequestInit) => {
      try {
        shapes[name] = mbs(S, await timeIt(quick ? 5 : 11, async (i) => post(await make(i), extra)));
      } catch (e) {
        shapes[name] = `unsupported: ${(e as Error).message.slice(0, 60)}`;
      }
    };
    await shape("Uint8Array", () => flat);
    await shape("new Blob([Uint8Array])", () => new Blob([flat]));
    await shape("new Blob(167 ArrayBuffers)", () => new Blob(parts));
    await shape("File.slice(), no JS read", (i) => file.slice(offs(i, S), offs(i, S) + S));
    await shape("read + new Blob([u8]) (block path)", async (i) => new Blob([new Uint8Array(await file.slice(offs(i, S), offs(i, S) + S).arrayBuffer())]));
    await shape("read -> Uint8Array body", async (i) => new Uint8Array(await file.slice(offs(i, S), offs(i, S) + S).arrayBuffer()));
    await shape("ReadableStream, duplex half", () => file.slice(0, S).stream(), { duplex: "half" } as RequestInit);
    out.shapes = shapes;

    // 3. parallelism: N concurrent 8 MiB uploads (read + Blob, like the engine)
    const par: Record<string, number> = {};
    for (const n of [1, 2, 3, 4, 6, 8, 12]) {
      const total = quick ? 24 : 64;
      let next = 0;
      const a = performance.now();
      await Promise.all(
        Array.from({ length: n }, async () => {
          while (next < total) {
            const i = next++;
            await post(new Blob([new Uint8Array(await file.slice(offs(i, S), offs(i, S) + S).arrayBuffer())]));
          }
        }),
      );
      par[`${n} concurrent`] = mbs(total * S, performance.now() - a);
    }
    out.parallel = par;
    return out;
  },
  { base: server.base, token: server.token, quick },
);

const engine = await page.evaluate(
  async ({ base, token, quick }) => {
    const sd = (globalThis as any).sd;
    const file = (document.getElementById("f") as HTMLInputElement).files![0]!;
    const rows: Record<string, unknown>[] = [];
    const n = quick ? 2000 : 10_000;
    const scenarios: Array<[string, () => any[]]> = [
      ["1 GB file", () => [{ id: "file_big0001", name: "big.bin", relDir: "", size: file.size, type: "", lastModified: 0, blob: file }]],
      [
        `${n.toLocaleString("en")} x 50 KB`,
        () =>
          Array.from({ length: n }, (_, i) => {
            const at = (i * 50_000) % (file.size - 50_000);
            return { id: `file_${String(i).padStart(7, "0")}`, name: `IMG_${i}.jpg`, relDir: "", size: 50_000, type: "image/jpeg", lastModified: 0, blob: file.slice(at, at + 50_000) };
          }),
      ],
    ];
    for (const [name, files] of scenarios) {
      const job = new sd.TransferJob({ transport: new sd.HttpTransport({ baseUrl: base, token }), files: files(), direction: "to-host", label: name, bench: true });
      const a = performance.now();
      await job.start();
      await Promise.race([job.done, new Promise<void>((r) => job.onChange((j: any) => j.state === "paused" && r()))]);
      const secs = (performance.now() - a) / 1000;
      const s = job.snapshot();
      const t = job.telemetry();
      const st = t.stages;
      const sum = st.readMs + st.hashMs + st.frameMs + st.networkMs + st.completeMs || 1;
      const heap = (performance as any).memory?.usedJSHeapSize;
      rows.push({
        scenario: name,
        state: s.state,
        MBs: Math.round(s.bytesTotal / 1e6 / secs),
        filesPerSec: Math.round(s.filesTotal / secs),
        streams: s.streams,
        chunkMiB: s.chunkBytes / (1 << 20),
        peakInflightMiB: Math.round(t.peakInflightBytes / (1 << 20)),
        stages: `read ${Math.round((st.readMs / sum) * 100)} hash ${Math.round((st.hashMs / sum) * 100)} frame ${Math.round((st.frameMs / sum) * 100)} net ${Math.round((st.networkMs / sum) * 100)} complete ${Math.round((st.completeMs / sum) * 100)}`,
        heapMB: heap ? Math.round(heap / 1e6) : null,
      });
    }
    return rows;
  },
  { base: server.base, token: server.token, quick },
);

console.log("primitives (MB/s):");
console.table(results.primitives);
console.log("request body shape, 8 MiB, one at a time (MB/s):");
console.table(results.shapes);
console.log("concurrent 8 MiB read+upload (aggregate MB/s):");
console.table(results.parallel);
console.log("engine in the browser -> server sink:");
console.table(engine);
const outDir = join(import.meta.dirname, "results");
await mkdir(outDir, { recursive: true });
await writeFile(join(outDir, `browser-chromium${tag ? `-${tag}` : ""}.json`), JSON.stringify({ at: new Date().toISOString(), rev: gitRev(), ua, ...results, engine }, null, 2));
await browser.close();
await server.close();
await src.dispose();
