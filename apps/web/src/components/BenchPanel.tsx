import { formatBytes, formatDuration } from "@swiftdrop/shared";
import { DESKTOP_CONTROLLER, HttpTransport, MOBILE_CONTROLLER, TransferJob, type SourceFile } from "@swiftdrop/transfer-engine";
import { useRef, useState } from "react";
import { Api, getToken } from "../lib/api.ts";
import { isMobile } from "../lib/env.ts";
import { useAppState } from "../lib/reading.ts";
import { fromJob, useTick } from "../lib/reading.ts";
import { TransferFocus } from "./TransferFocus.tsx";

/**
 * Development benchmark (open /#/bench). Runs the real engine over the real network into
 * the server's verify-only sink: every block is hashed and checked, nothing touches disk.
 * Inputs are virtual files generated on read, so a 10 GB run needs no 10 GB of anything.
 */

const MB = 1e6;
const SCENARIOS = [
  { name: "100 MB file", files: [[1, 100 * MB]] },
  { name: "1 GB file", files: [[1, 1000 * MB]] },
  { name: "5 GB file", files: [[1, 5000 * MB]] },
  { name: "10 GB file", files: [[1, 10_000 * MB]] },
  { name: "1,000 small (200 KB)", files: [[1000, 200_000]] },
  { name: "10,000 small (50 KB)", files: [[10_000, 50_000]] },
] as const;

interface Row {
  scenario: string;
  avg: number;
  peak: number;
  secs: number;
  streams: number;
  chunk: number;
  retries: number;
  failures: number;
  serverCpu: number;
  serverRss: number;
  clientHeap: number | null;
}

const noise = (() => {
  const b = new Uint8Array(16 << 20);
  for (let i = 0; i < b.length; i += 4) b[i] = (i * 2654435761) >>> 24;
  return b;
})();

function virtualBlob(size: number, seed: number): Blob {
  const make = (from: number, to: number): Blob =>
    ({
      size: to - from,
      type: "",
      slice: (a = 0, b = to - from) => make(from + a, from + Math.min(b, to - from)),
      arrayBuffer: async () => {
        const out = new Uint8Array(to - from);
        for (let o = 0; o < out.length; ) {
          const at = (from + o + seed * 7919) % noise.length;
          const n = Math.min(out.length - o, noise.length - at);
          out.set(noise.subarray(at, at + n), o);
          o += n;
        }
        return out.buffer;
      },
    }) as unknown as Blob;
  return make(0, size);
}

export function BenchPanel() {
  const { rtt } = useAppState();
  const [rows, setRows] = useState<Row[]>([]);
  const [job, setJob] = useState<TransferJob | null>(null);
  const [integrity, setIntegrity] = useState<"xxh64" | "sha256">("xxh64");
  const stop = useRef(false);
  useTick(250, Boolean(job));

  async function run(which: (typeof SCENARIOS)[number][]) {
    stop.current = false;
    for (const sc of which) {
      if (stop.current) break;
      let n = 0;
      const files: SourceFile[] = [];
      for (const [count, size] of sc.files)
        for (let i = 0; i < count; i++) files.push({ id: `file_${(n++).toString(36).padStart(6, "0")}`, name: `b${n}.bin`, relDir: "", size, type: "", lastModified: Date.now(), blob: virtualBlob(size, n) });
      const j = new TransferJob({
        transport: new HttpTransport({ baseUrl: location.origin, ...(getToken() ? { token: getToken()! } : {}) }),
        files,
        direction: "to-host",
        label: sc.name,
        bench: true,
        integrity,
        controller: isMobile ? MOBILE_CONTROLLER : DESKTOP_CONTROLLER,
      });
      setJob(j);
      const s0 = await Api.stats().catch(() => null);
      const t0 = performance.now();
      let peak = 0;
      const poll = setInterval(() => (peak = Math.max(peak, j.snapshot().peak)), 250);
      await j.start();
      await Promise.race([j.done, new Promise<void>((r) => j.onChange((x) => x.state === "paused" && r()))]);
      clearInterval(poll);
      const secs = (performance.now() - t0) / 1000;
      const s1 = await Api.stats().catch(() => null);
      const snap = j.snapshot();
      const mem = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
      setRows((r) => [
        ...r,
        {
          scenario: sc.name,
          avg: snap.bytesTotal / secs,
          peak: Math.max(peak, snap.peak),
          secs,
          streams: snap.streams,
          chunk: snap.chunkBytes,
          retries: snap.retries,
          failures: snap.chunkFailures,
          serverCpu: s0 && s1 ? ((s1.cpuUserMs + s1.cpuSystemMs - s0.cpuUserMs - s0.cpuSystemMs) / 1000 / secs) * 100 : 0,
          serverRss: s1?.rss ?? 0,
          clientHeap: mem?.usedJSHeapSize ?? null,
        },
      ]);
    }
    setJob(null);
  }

  return (
    <div className="flex flex-col gap-5">
      <section className="flex flex-col gap-5 pt-10">
        <h1 className="t-h1">Benchmark</h1>
        <p className="t-body">
          Real engine, real network, receiver verifies every block and discards it. Measures what this device and this Wi-Fi can do; disk is not involved.
        </p>
        <div className="flex flex-wrap gap-2">
          <button className="btn btn-primary" disabled={Boolean(job)} onClick={() => void run([SCENARIOS[0], SCENARIOS[1], SCENARIOS[4], SCENARIOS[5]])}>
            Run standard set
          </button>
          {SCENARIOS.map((s) => (
            <button key={s.name} className="btn btn-secondary btn-sm" disabled={Boolean(job)} onClick={() => void run([s])}>
              {s.name}
            </button>
          ))}
          {job && (
            <button className="btn btn-danger" onClick={() => ((stop.current = true), void job.cancel())}>
              Stop
            </button>
          )}
        </div>
        <label className="flex items-center gap-2">
          <input type="checkbox" checked={integrity === "sha256"} onChange={(e) => setIntegrity(e.target.checked ? "sha256" : "xxh64")} />
          Use SHA-256 block digests (default xxh64)
        </label>
      </section>
      {job && <TransferFocus r={fromJob(job, "guest")} rtt={rtt} peer="your PC" perspective="guest" onDone={() => undefined} />}
      {rows.length > 0 && (
        <div className="surface overflow-x-auto p-4">
          <table className="w-full num text-[0.95rem]" style={{ borderCollapse: "collapse" }}>
            <thead>
              <tr className="text-left t-small">
                {["Scenario", "Avg", "Peak", "Time", "Streams", "Chunk", "Retries", "Bad chunks", "PC CPU", "PC RSS", "Page heap"].map((h) => (
                  <th key={h} className="py-1.5 pr-4 font-semibold">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i} className="border-t" style={{ borderColor: "var(--hairline)" }}>
                  <td className="py-1.5 pr-4">{r.scenario}</td>
                  <td className="pr-4">{(r.avg / MB).toFixed(1)} MB/s</td>
                  <td className="pr-4">{(r.peak / MB).toFixed(1)} MB/s</td>
                  <td className="pr-4">{formatDuration(r.secs)}</td>
                  <td className="pr-4">{r.streams}</td>
                  <td className="pr-4">{formatBytes(r.chunk, 0)}</td>
                  <td className="pr-4">{r.retries}</td>
                  <td className="pr-4">{r.failures}</td>
                  <td className="pr-4">{r.serverCpu.toFixed(0)}%</td>
                  <td className="pr-4">{formatBytes(r.serverRss)}</td>
                  <td className="pr-4">{r.clientHeap === null ? "n/a" : formatBytes(r.clientHeap)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <button className="btn btn-ghost mt-3" onClick={() => void navigator.clipboard?.writeText(JSON.stringify(rows, null, 2))}>
            Copy results as JSON
          </button>
        </div>
      )}
    </div>
  );
}
