import { BLOCK_SIZE } from "@swiftdrop/protocol";
import { Bitset } from "@swiftdrop/shared";
import { describe, expect, it } from "vitest";
import { AdaptiveController, DESKTOP_CONTROLLER, MOBILE_CONTROLLER, type ControllerSample } from "./controller.ts";
import { Planner } from "./planner.ts";
import { SpeedMeter } from "./speed-meter.ts";

const MB = 1_000_000;
const sample = (throughput: number, extra: Partial<ControllerSample> = {}): ControllerSample => ({
  throughput,
  avgLatencyMs: 500,
  completed: 10,
  errors: 0,
  serverLoad: 0,
  ...extra,
});

/** Simulated link: throughput saturates at `knee` streams, degrades past `collapse`. */
function link(streams: number, knee: number, perStream = 25 * MB, collapse = 99) {
  const base = Math.min(streams, knee) * perStream;
  return streams > collapse ? base * 0.7 : base;
}

describe("AdaptiveController", () => {
  it("climbs to the saturation point and holds there", () => {
    const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, settleSamples: 0 });
    for (let i = 0; i < 12; i++) c.update(sample(link(c.streams, 4)));
    expect(c.streams).toBe(4);
  });

  it("stops at the max when every stream helps", () => {
    const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, settleSamples: 0 });
    for (let i = 0; i < 20; i++) c.update(sample(link(c.streams, 10)));
    expect(c.streams).toBe(6);
  });

  it("halves on errors", () => {
    const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, initialStreams: 6, settleSamples: 0 });
    const d = c.update(sample(10 * MB, { errors: 2 }));
    expect(d.reason).toBe("errors");
    expect(c.streams).toBe(3);
  });

  it("backs off when the receiver reports pressure", () => {
    const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, initialStreams: 4 });
    expect(c.update(sample(50 * MB, { serverLoad: 0.95 })).reason).toBe("receiver-busy");
    expect(c.streams).toBe(3);
  });

  it("grows chunks when requests are quick, shrinks when slow", () => {
    const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, initialBlocks: 2, settleSamples: 0 });
    c.update(sample(80 * MB, { avgLatencyMs: 60 }));
    expect(c.blocksPerChunk).toBe(4);
    for (let i = 0; i < 4; i++) c.update(sample(80 * MB, { avgLatencyMs: 4000 }));
    expect(c.blocksPerChunk).toBe(1);
  });

  it("respects the iOS memory budget", () => {
    const c = new AdaptiveController({ ...MOBILE_CONTROLLER, settleSamples: 0 });
    for (let i = 0; i < 30; i++) {
      c.update(sample(link(c.streams, 10), { avgLatencyMs: 50 }));
      expect(c.streams * c.blocksPerChunk * BLOCK_SIZE).toBeLessThanOrEqual(MOBILE_CONTROLLER.memoryBudget);
    }
  });

  it("re-learns after the link collapses", () => {
    const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, settleSamples: 0 });
    for (let i = 0; i < 12; i++) c.update(sample(link(c.streams, 5)));
    const held = c.streams;
    const d = c.update(sample(5 * MB));
    c.update(sample(5 * MB));
    expect(["reprobe", "probe-reverted", "probe-up"]).toContain(d.reason);
    expect(c.streams).toBeLessThanOrEqual(held);
  });

  it("waits for enough finished requests before judging a level", () => {
    const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, settleSamples: 0 });
    // 2 completions per sample: needs 3 samples to reach 6
    expect(c.update(sample(50 * MB, { completed: 2 })).reason).toBe("measuring");
    expect(c.update(sample(50 * MB, { completed: 2 })).reason).toBe("measuring");
    expect(c.update(sample(50 * MB, { completed: 2 })).reason).toBe("probe-up");
    // a trickle still gets judged after maxWindowSamples
    const slow = new AdaptiveController({ ...DESKTOP_CONTROLLER, settleSamples: 0 });
    const reasons = Array.from({ length: 4 }, () => slow.update(sample(2 * MB, { completed: 0, avgLatencyMs: 3000 })).reason);
    expect(reasons).toEqual(["measuring", "measuring", "measuring", "probe-up"]);
  });

  it("is not fooled by request-boundary quantization at phone speeds", () => {
    // Link saturates at 3 streams. Each 1 s sample holds ~3 completions of big chunks, so
    // whether a request lands just before or after the boundary swings a sample by ±25%.
    for (const phase of [0, 1]) {
      const c = new AdaptiveController({ ...DESKTOP_CONTROLLER, settleSamples: 1 });
      let changes = 0;
      for (let i = 0; i < 80; i++) {
        const noise = (i + phase) % 2 === 0 ? 1.25 : 0.75;
        const before = c.streams;
        c.update(sample(link(c.streams, 3, 10 * MB) * noise, { completed: 3, avgLatencyMs: 600 }));
        if (c.streams !== before) changes++;
      }
      expect(c.streams).toBe(3);
      // climb 3→4, revert, then periodic re-probes (up + back) only
      expect(changes).toBeLessThanOrEqual(8);
    }
  });
});

describe("SpeedMeter", () => {
  it("averages over the window and decays when idle", () => {
    let t = 0;
    const m = new SpeedMeter(3000, () => t);
    m.start();
    for (let i = 0; i < 30; i++) {
      t += 100;
      m.add(10 * MB); // 100 MB/s
    }
    expect(m.rate()).toBeGreaterThan(95 * MB);
    expect(m.rate()).toBeLessThan(105 * MB);
    t += 3100;
    expect(m.rate()).toBe(0);
    expect(m.average()).toBeGreaterThan(40 * MB);
  });

  it("does not count paused time in the average", () => {
    let t = 0;
    const m = new SpeedMeter(3000, () => t);
    m.start();
    t += 1000;
    m.add(100 * MB);
    m.stop();
    t += 60_000;
    m.start();
    expect(m.average()).toBeCloseTo(100 * MB, -3);
  });
});

describe("Planner", () => {
  const MiB = BLOCK_SIZE;
  it("splits large files into ranges and batches small ones", () => {
    const p = new Planner(
      [
        { id: "file_big01", size: 5 * MiB + 10 },
        { id: "file_sm001", size: 1000 },
        { id: "file_sm002", size: 2000 },
      ],
      MiB,
    );
    const items = [];
    for (let it = p.next(2); it; it = p.next(2)) items.push(it);
    const ranges = items.filter((i) => i.kind === "blocks");
    const batches = items.filter((i) => i.kind === "batch");
    expect(ranges.map((r) => (r.kind === "blocks" ? [r.start, r.count] : []))).toEqual([
      [0, 2],
      [2, 2],
      [4, 2],
    ]);
    expect(batches).toHaveLength(1);
    expect(batches[0]!.kind === "batch" && batches[0]!.files.map((f) => f.id)).toEqual(["file_sm001", "file_sm002"]);
  });

  it("re-offers released ranges and never re-sends acked blocks", () => {
    const p = new Planner([{ id: "file_big01", size: 4 * MiB }], MiB);
    const a = p.next(2)!;
    const b = p.next(2)!;
    p.ack(a);
    p.release(b);
    const again = p.next(2)!;
    expect(again.kind === "blocks" && again.start).toBe(2);
    p.ack(again);
    const confirm = p.next(2)!;
    expect(confirm.kind).toBe("complete");
    p.ack(confirm);
    expect(p.finished).toBe(true);
  });

  it("resumes from a receiver bitmap", () => {
    const p = new Planner([{ id: "file_big01", size: 10 * MiB }], MiB);
    const have = new Bitset(10);
    for (let i = 0; i < 9; i++) have.set(i);
    p.applyStatus({ transferId: "tr_abcdef", blockSize: MiB, integrity: "xxh64", files: [{ id: "file_big01", state: "partial", received: have.toBase64() }] });
    const it = p.next(4)!;
    expect(it.kind === "blocks" && [it.start, it.count]).toEqual([9, 1]);
    expect(p.ackedBytes(p.files[0]!)).toBe(9 * MiB);
  });

  it("queues confirmation for files fully received but never confirmed", () => {
    const p = new Planner([{ id: "file_big01", size: 2 * MiB }], MiB);
    const have = new Bitset(2);
    have.set(0);
    have.set(1);
    p.applyStatus({ transferId: "tr_abcdef", blockSize: MiB, integrity: "xxh64", files: [{ id: "file_big01", state: "partial", received: have.toBase64() }] });
    expect(p.next(4)!.kind).toBe("complete");
  });
});
