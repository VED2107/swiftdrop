/**
 * Cross-language test vectors: what the TypeScript implementation produces for every
 * operation that crosses the wire or decides transfer behaviour. The Dart port
 * (packages/swiftdrop_core) asserts it produces exactly the same.
 *
 *   pnpm vectors          regenerate tests/vectors/protocol-v1.json
 *   vectors.test.ts       fails when the TS code no longer matches the committed file
 */
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bytesToBase64Url, createBlockHasher, type HashAlgo } from "@swiftdrop/crypto";
import { BLOCK_SIZE, CreateTransferSchema, encodeBatchHeader, TransferStatusSchema } from "@swiftdrop/protocol";
import { Bitset, formatBytes, formatDuration, formatRate, numberedName, sanitizeFileName, sanitizeRelativeDir } from "@swiftdrop/shared";
import {
  AdaptiveController,
  DESKTOP_CONTROLLER,
  MOBILE_CONTROLLER,
  Planner,
  type ControllerSample,
  type WorkItem,
} from "@swiftdrop/transfer-engine";

export const VECTORS_PATH = join(dirname(fileURLToPath(import.meta.url)), "protocol-v1.json");

/** Deterministic bytes (xorshift32), reproduced byte-for-byte by the Dart tests. */
export function patternBytes(seed: number, length: number): Uint8Array {
  const out = new Uint8Array(length);
  let x = seed >>> 0 || 1;
  for (let i = 0; i < length; i++) {
    x ^= x << 13;
    x >>>= 0;
    x ^= x >>> 17;
    x ^= x << 5;
    x >>>= 0;
    out[i] = x & 0xff;
  }
  return out;
}

const HASH_CASES: Array<[seed: number, length: number]> = [
  [1, 0],
  [2, 1],
  [3, 7],
  [4, 1000],
  [5, BLOCK_SIZE],
  [6, BLOCK_SIZE + 1],
  [7, Math.floor(2.5 * BLOCK_SIZE) + 3],
];

async function hashes() {
  const out: Record<HashAlgo, Array<{ seed: number; length: number; blocks: string; root: string }>> = { xxh64: [], sha256: [] };
  for (const algo of ["xxh64", "sha256"] as const) {
    const h = await createBlockHasher(algo);
    for (const [seed, length] of HASH_CASES) {
      const digests = h.hashBlocks(patternBytes(seed, length), BLOCK_SIZE);
      out[algo].push({ seed, length, blocks: bytesToBase64Url(digests), root: h.root(digests) });
    }
  }
  return out;
}

function bitsets() {
  const cases: Array<{ size: number; set: number[] }> = [
    { size: 0, set: [] },
    { size: 1, set: [0] },
    { size: 9, set: [0, 3, 8] },
    { size: 20, set: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 0] },
    { size: 37, set: [5, 6, 7, 30, 36] },
  ];
  return cases.map((c) => {
    const b = new Bitset(c.size);
    for (const i of c.set) b.set(i);
    return { ...c, base64: b.toBase64(), count: b.count, complete: b.complete, missingRuns: b.missingRuns() };
  });
}

function base64url() {
  return [0, 1, 2, 3, 4, 5, 31, 32, 33].map((n) => ({ seed: 11 + n, length: n, text: bytesToBase64Url(patternBytes(11 + n, n)) }));
}

async function batchFrames() {
  const h = await createBlockHasher("xxh64");
  const files = [
    { id: "f_000001", data: patternBytes(21, 10) },
    { id: "f_000002", data: patternBytes(22, 0) },
    { id: "f_000003", data: patternBytes(23, 300) },
  ];
  const header = encodeBatchHeader({
    files: files.map((f) => ({ id: f.id, size: f.data.length, hash: bytesToBase64Url(h.hashBlocks(f.data, BLOCK_SIZE)) })),
  });
  const frame = new Uint8Array(header.length + files.reduce((s, f) => s + f.data.length, 0));
  frame.set(header);
  let at = header.length;
  for (const f of files) {
    frame.set(f.data, at);
    at += f.data.length;
  }
  return [{ files: files.map((f, i) => ({ id: f.id, seed: 21 + i, length: f.data.length })), frame: bytesToBase64Url(frame) }];
}

function sanitizing() {
  const names = [
    "IMG_0001.HEIC",
    "  report.pdf  ",
    "a/b\\c.txt",
    "CON",
    "con.txt",
    "LPT1.log",
    "trailing dots...",
    "..",
    "",
    "tab\there",
    "e\u0301cole.txt",
    "evil\u202Etxt.exe",
    "x".repeat(200) + ".jpeg",
    'what?<>:"|*.txt',
  ];
  const dirs = ["", "DCIM/100APPLE", "../../etc", "a//b/./c", "C:\\Users\\x", " spaced / dir ", "nul/aux"];
  return {
    fileNames: names.map((input) => ({ input, output: sanitizeFileName(input) })),
    relDirs: dirs.map((input) => ({ input, output: sanitizeRelativeDir(input) })),
    numbered: [
      ["IMG_001.jpg", 2],
      ["README", 3],
      [".bashrc", 2],
      ["archive.tar.gz", 10],
    ].map(([name, n]) => ({ name, n, output: numberedName(name as string, n as number) })),
  };
}

function formatting() {
  const bytes = [0, -5, 999, 1000, 1536000, 123456789, 1.8e9, 5.3e12];
  const durations = [0, 72, 3723, -1, 59.6];
  return {
    bytes: bytes.map((v) => ({ value: v, output: formatBytes(v) })),
    rates: [94e6, 1234].map((v) => ({ value: v, output: formatRate(v) })),
    durations: durations.map((v) => ({ value: v, output: formatDuration(v) })),
  };
}

/** A fixed stream of samples covering probing, holding, errors, pressure, collapse, idle. */
export function controllerSamples(): ControllerSample[] {
  const s: ControllerSample[] = [];
  const add = (throughput: number, avgLatencyMs: number, completed: number, errors = 0, serverLoad = 0, times = 1) => {
    for (let i = 0; i < times; i++) s.push({ throughput, avgLatencyMs, completed, errors, serverLoad });
  };
  add(20e6, 180, 3, 0, 0, 3); // short requests: chunk grows
  add(30e6, 300, 4, 0, 0, 4);
  add(40e6, 400, 6, 0, 0, 4);
  add(41e6, 420, 6, 0, 0, 6); // probe doesn't pay: revert, hold
  add(41e6, 2000, 2, 0, 0, 3); // slow requests: chunk shrinks
  add(0, 0, 0, 0, 0, 2); // idle
  add(38e6, 500, 6, 1); // error: halve
  add(38e6, 500, 6, 0, 0.9); // receiver busy
  add(40e6, 500, 6, 0, 0, 14); // hold long enough to re-probe
  add(15e6, 500, 6, 0, 0, 3); // collapse: re-learn
  return s;
}

function controllers() {
  const samples = controllerSamples();
  return (["desktop", "mobile"] as const).map((name) => {
    const c = new AdaptiveController(name === "desktop" ? DESKTOP_CONTROLLER : MOBILE_CONTROLLER);
    return { config: name, samples, decisions: samples.map((x) => c.update(x)) };
  });
}

type ItemDesc = { kind: string; file?: string; files?: string[]; start?: number; count?: number; bytes?: number };
function describe(item: WorkItem | null): ItemDesc | null {
  if (!item) return null;
  if (item.kind === "complete") return { kind: "complete", file: item.file.id };
  if (item.kind === "blocks") return { kind: "blocks", file: item.file.id, start: item.start, count: item.count };
  return { kind: "batch", files: item.files.map((f) => f.id), bytes: item.bytes };
}

/**
 * Planner trace: a scripted sequence of next / ack / release / applyStatus operations and
 * the planner's answer to each. Dart replays the same operations and must match.
 */
function planners() {
  const files = [
    { id: "f_large1", size: Math.floor(3.5 * BLOCK_SIZE) },
    { id: "f_small1", size: 100_000 },
    { id: "f_empty1", size: 0 },
    { id: "f_mid001", size: 600_000 },
    { id: "f_large2", size: 2 * BLOCK_SIZE },
    { id: "f_small2", size: 10_000 },
    { id: "f_small3", size: 10_000 },
    { id: "f_small4", size: 10_000 },
  ];
  const p = new Planner(files, BLOCK_SIZE);
  const ops: Array<Record<string, unknown>> = [];
  const items: WorkItem[] = [];

  const status = TransferStatusSchema.parse({
    transferId: "tr_vector",
    blockSize: BLOCK_SIZE,
    integrity: "xxh64",
    files: files.map((f) => ({ id: f.id, state: "new" })),
  });
  p.applyStatus(status);
  ops.push({ op: "applyStatus", status });

  const next = (bpc: number) => {
    const item = p.next(bpc);
    if (item) items.push(item);
    ops.push({ op: "next", blocksPerChunk: bpc, result: describe(item), finished: p.finished });
    return item;
  };
  const ack = (i: number) => ops.push({ op: "ack", item: i, completed: p.ack(items[i]!).map((f) => f.id), finished: p.finished });
  const release = (i: number) => {
    p.release(items[i]!);
    ops.push({ op: "release", item: i, finished: p.finished });
  };

  for (let k = 0; k < 4; k++) next(2);
  ack(0);
  release(1);
  ack(2);
  for (let k = 0; k < 3; k++) next(1);
  ack(3);
  release(4);

  // Resume: the receiver has blocks 0,2 of f_large1, f_small1 complete, f_mid001 skipped.
  const partial = new Bitset(4);
  partial.set(0);
  partial.set(2);
  const resumed = TransferStatusSchema.parse({
    transferId: "tr_vector",
    blockSize: BLOCK_SIZE,
    integrity: "xxh64",
    files: files.map((f) =>
      f.id === "f_large1"
        ? { id: f.id, state: "partial", received: partial.toBase64() }
        : f.id === "f_small1"
          ? { id: f.id, state: "complete", finalName: "f_small1" }
          : f.id === "f_mid001"
            ? { id: f.id, state: "skipped" }
            : { id: f.id, state: "new" },
    ),
  });
  p.applyStatus(resumed);
  ops.push({ op: "applyStatus", status: resumed });
  items.length = 0;
  let item: WorkItem | null;
  let guard = 0;
  while ((item = next(4)) && guard++ < 40) ack(items.length - 1);
  // A file's completion was rejected: start it over.
  const large2 = p.files.find((f) => f.id === "f_large2")!;
  p.resetFile(large2);
  ops.push({ op: "resetFile", file: "f_large2", finished: p.finished });
  while ((item = next(16)) && guard++ < 80) ack(items.length - 1);
  return [{ files, ops }];
}

function manifests() {
  const inputs = [
    {
      protocol: 1,
      transferId: "tr_abcdef",
      direction: "to-peer",
      files: [{ id: "f_000001", name: "a.txt", size: 3 }],
    },
    {
      protocol: 1,
      transferId: "tr_0123456789",
      direction: "to-host",
      label: "Photos",
      integrity: "sha256",
      onConflict: "keep-both",
      decisions: { f_000002: "skip" },
      bench: false,
      files: [
        { id: "f_000001", name: "IMG_0001.HEIC", relDir: "DCIM/100APPLE", size: 2400000, type: "image/heic", lastModified: 1759200000000 },
        { id: "f_000002", name: "clip.mov", size: 0 },
      ],
    },
  ];
  return inputs.map((input) => ({ input, parsed: CreateTransferSchema.parse(input) }));
}

export async function buildVectors() {
  return {
    note: "Generated by tests/vectors/generate.ts from the TypeScript implementation. Do not edit by hand.",
    blockSize: BLOCK_SIZE,
    pattern: "xorshift32: x^=x<<13; x^=x>>>17; x^=x<<5 (uint32), byte = x & 0xff, seed 0 treated as 1",
    hashes: await hashes(),
    base64url: base64url(),
    bitsets: bitsets(),
    batchFrames: await batchFrames(),
    sanitize: sanitizing(),
    format: formatting(),
    controllers: controllers(),
    planners: planners(),
    manifests: manifests(),
  };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const v = await buildVectors();
  writeFileSync(VECTORS_PATH, JSON.stringify(v, null, 1) + "\n");
  console.log(`wrote ${VECTORS_PATH}`);
}
