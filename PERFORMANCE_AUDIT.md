# SwiftDrop performance audit

Status: **measurement phase complete; optimizations being applied (✅ in §6).** Everything below was measured on one machine; nothing is estimated. Where a question could not be measured here (iPhone Safari, real Wi-Fi), that is said explicitly.

Test machine: Intel i5-10300H (4C/8T), 17 GB RAM, NVMe system drive (NTFS, Windows 11, Defender on), Node v24.13.0, Chromium 153 headless.

## 1. Current architecture (one byte, sender file → receiver disk)

```
Sender (browser / engine)                                   Receiver (Node server on the PC)
File ─slice─► Blob ─arrayBuffer()─► ArrayBuffer   [copy 1]
                                   │ xxh64 per 1 MiB block (wasm, copies into wasm memory) [copy 2]
                                   ▼
                     new Blob([u8]) in HttpTransport [copy 3]
                                   ▼
                     fetch PUT …/blocks/:start  ──── TCP ────► socket chunks
                                                                 │ readBody: one preallocated Buffer [copy 4]
                                                                 │ xxh64 verify (wasm) [copy 5]
                                                                 │ fh.write(positional) → .part   [kernel copy]
                     ◄──────────── 204 + x-sd-load ─────────────┘
Small files (≤512 KiB): per-file arrayBuffer() → hash → new Blob([header, ...buffers]) → POST /batch
                        → receiver verifies whole frame → open(wx)+write+close per file, 16 in parallel.
```

- Control plane: JSON (manifest, status bitmaps, completion roots) + WebSocket events. Data plane: raw binary bodies; the only per-request overhead is the `x-sd-hashes` header (11 chars per MiB).
- ACKs are per request and cover the whole range (1–16 blocks); no stop-and-wait: up to 6 requests in flight (browser per-host cap).
- The adaptive controller hill-climbs streams (start 3, cap 6) and sizes chunks to a 250–900 ms latency target, bounded by a memory budget (48 MiB iOS / 128 MiB desktop).
- Resume state: bitmaps + block digests persisted every 1 s; network drops resend only missing blocks (covered by integration tests).
- UI never sees chunk events: it polls `job.snapshot()` on a clock (`useTick`), state lives in external stores.

## 2. Measurement tooling added

| Tool | What it measures |
|---|---|
| `tests/performance/primitives.ts` | cost of each data-path primitive in Node (reads, copies, Blob, hashes, writes, small-file creates) |
| `tests/performance/bench.ts` | engine → real server **in a separate process**, scenarios A–H, sink or disk, `--sweep` streams×chunk grid, `--check` budgets |
| `tests/performance/browser-bench.ts` | real Chromium with real disk `File`s: primitives, request-body shapes, concurrency, full engine runs |
| `tests/performance/disk-bench.ts` | disk alone: sequential, parallel-range, small-file create rates by parallelism and folder count |
| `tests/performance/store-bench.ts` | receiver store alone (batch frames → disk, no network) |
| `tests/performance/profile-summary.mjs` | self-time summary of a `--cpu-prof` profile (`SD_SERVER_NODE_ARGS="--cpu-prof …"`) |
| Engine `job.telemetry()` | per-stage time (read/hash/frame/network/complete), prepare time, in-flight bytes + peak, p50/p95 throughput and request latency, wire bytes |
| Server `/api/stats` → `pipeline` | receiver recv/hash/write time, write-queue bytes + peak, write latency p50/p95, files created |

Methodology fix: the old bench ran sender and receiver in **one Node process**. They shared an event loop, so each stalled the other and CPU could not be attributed. Moving the receiver into its own process changed the 1 GB result from 257 MB/s to 479 MB/s with no engine change. The old numbers measured the harness, not SwiftDrop.

## 3. Measured results (loopback: software ceiling, not Wi-Fi)

Engine (Node sender) → server, xxh64, `results/bench-*-before.json`:

| Scenario | sink MB/s | disk MB/s | disk files/s | sender CPU | receiver CPU | receiver RSS |
|---|---:|---:|---:|---:|---:|---:|
| A 100 MB | 398 | 382 | – | 143–197% | 149–162% | ~100 MB |
| B 1 GB | 479 | 447 | – | 180–212% | 142–148% | 156–187 MB |
| E 1,000 × 10 KB | 66 | 21 | 2,128 | | 166% | 169 MB |
| F 1,000 × 100 KB | 270 | 123 | 1,230 | | 127% | 130 MB |
| G 10,000 × 50 KB | 232 | 78 | 1,567 | | 142% | 241 MB |
| H mixed | 432 | 378 | 120 | | 190% | 247 MB |

Chromium (real `File` from disk) → server sink, `results/browser-chromium-before.json`:

| | MB/s |
|---|---:|
| `File.slice(16 MiB).arrayBuffer()` | 1,029 |
| xxh64 wasm / sha256 wasm | 7,626 / 241 |
| 160 × 50 KB slices → `arrayBuffer()` in parallel | **196** |
| one 8 MiB upload, body = `Blob` (any shape) / `File.slice()` | **~30** |
| one 8 MiB upload, body = `Uint8Array` | **9** |
| body = `ReadableStream` (`duplex: "half"`) | fails over HTTP/1.1 |
| N concurrent 8 MiB uploads, aggregate | 28 → 35 → 40 (N=1,2,3), flat at 40 up to N=12 |
| full engine, 1 GB | 38 |
| full engine, 10,000 × 50 KB | 33 (659 files/s) |

## 4. Hotspot map

1 GB, sink, share of summed request lifetime (sender) and receiver main-thread profile:

```
sender  read (File → ArrayBuffer)    13%
sender  hash (xxh64)                  3%
sender  frame                         0%
wire + receiver                      84%
   receiver main thread idle         52%   ← receiver is not the limit
   receiver body copy (_copyActual)   7%
   receiver xxh64 incl. wasm copy-in  6%
   GC                                 3%
```

10,000 × 50 KB to disk:

```
prepare (manifest + stat of every target name)   451 ms of 6.5 s   (7%)
receive 8 MB batch body                           ~80 ms   (vs ~16 ms for 8 MB of blocks: 5x)
store writes (open wx + write + close)            dominates; store alone lands 2,740 files/s
NTFS ceiling, one folder                          ~3,000–3,200 creates/s at parallelism >= 4
```

## 5. Bottlenecks

**Critical**
1. **Chromium upload path, ~40 MB/s aggregate on Windows loopback**, regardless of body type, from 3 concurrent requests on. Node pushes 520 MB/s into the same server, so the receiver is not the cause. This limits every Chromium-sent transfer, including **PC → phone staging**, which is a Chromium upload over loopback. Not yet explained. Candidates: Chromium's socket send buffer on Windows, or upload chunking. Next step: test headed Chrome/Edge and with larger server `SO_RCVBUF`, and consider having the server read the file directly for PC → phone (native file picker on the PC side) so the upload hop disappears.
2. **Small files: half the disk ceiling.** Store alone: 2,740 files/s. End-to-end: 1,567 files/s. The gap is in the pipeline (multi-part batch bodies arrive 5× slower, and each stream waits for its batch to be written).

**CPU**
- Receiver: ~1 ms CPU per small file, mostly kernel (NTFS create + Defender on close), charged to our threadpool threads; JS main thread is ≥50% idle.
- sha256 on the receiver uses wasm (219 MB/s); `node:crypto` does 437 MB/s. xxh64 (default) is never the bottleneck (6–7 GB/s).

**Memory**
- Bounded: receiver RSS ≤ 267 MB in every scenario, no growth with file size (1 GB and 100 MB runs are within 60 MB). Sender in-flight peaks 12–64 MiB.
- Chromium engine heap 167 MB during 1 GB and 10k-file runs.

**Network**
- No stop-and-wait. The controller settles at 3–4 streams on loopback. Concurrency stops paying at 3 in Chromium (35 → 40 → 40 MB/s).

**Disk (NVMe, NTFS, Defender on)**
- Sequential 1,203 MB/s; 4 parallel range writers 1,036 MB/s. The disk is never the limit for large files.
- Small files: ~1,800/s serial, ~3,200/s at parallelism ≥4 **in one folder** (flat at 4, 16 and 64). 5,000/s across 4 folders: NTFS serializes creates per directory.
- Hypotheses tested and rejected: libuv threadpool size (4/16/32/64: no change); file content affecting AV scan time (pattern/random/JPEG header: no change); directory size up to 10k entries (no change).

**Browser limits**
- 6 connections per host (HTTP/1.1). Streaming request bodies need HTTP/2+, so they are unavailable against a plain-HTTP LAN server. `crypto.subtle` is unavailable on `http://` LAN origins; wasm hashing is required.
- Reading many small `File` slices costs far more than one large read: 196 MB/s vs 1,039 MB/s.

**iOS (not measurable here, from platform constraints)**
- JavaScript stops when Safari is backgrounded or locked. A wake lock is requested, and the engine resumes from the receiver bitmap.
- Memory ceiling per tab: the mobile controller budget is 48 MiB in flight.
- The photo picker may transcode HEIC and video before the page sees the file.

**Windows**
- Per-directory create serialization, Defender scan on close, and 8.3 short-name generation (`fsutil 8dot3name` needs admin; not changed).

## 6. Proposed optimizations (ranked by measured headroom)

| # | Change | Evidence | Expected effect |
|---|---|---|---|
| 1 | ✅ For PC → phone, let the server read the picked file itself instead of staging through a browser upload | 40 MB/s browser vs 520 MB/s Node into the same server | done: native dialog, served in place; 1 GB offer ready in 18 ms instead of ~27 s (`native-offer-1gb.json`). The Chromium upload ceiling itself is still unexplained and still applies to drag-and-drop. |
| 2 | ✅ Batch body as one contiguous buffer | multi-part body 5× slower to arrive in Node; equal in Chromium | done: 10k × 50 KB 232 → 314 MB/s sink, 78 → 95 MB/s disk (`*-contig.json`) |
| 3 | ✅ Conflict check with one `readdir` per target folder instead of one `stat` per file | 451–660 ms prepare for 10k files | done: prepare 660 → 174–270 ms (`bench-disk-xxh64-dup-*.json`) |
| 4 | Read-ahead: prepare the next chunk while the current one is on the wire | sender read+hash = 16% of request life; connections capped at 6 | fills idle connection time when streams are at the cap |
| 5 | Controller judges probes on ≥N completed requests, not a fixed 1 s window | 16 MiB chunks at phone speeds = 3–6 completions/s → ±20% quantization noise | fewer false probes/reverts on real Wi-Fi |
| 6 | ✅ `node:crypto` sha256 on the receiver | 437 vs 219 MB/s | done: receiver hash 5,233 → 2,578 ms/GB (`bench-sink-sha256-nodesha-*.json`); end-to-end SHA-256 stays sender-bound (browser wasm) |
| 7 | Adaptive resume-state persist interval | full JSON rewrite every 1 s (50k files ≈ MBs per second) | lower receiver CPU on huge file counts |

## 7. Benchmark methodology

- Always two processes (engine and receiver), as in real use. Report sender and receiver CPU separately.
- Sources are real on-disk data read with positional reads (`diskBlob`); Node's `openAsBlob` reads 4× slower than `fs.read` and would benchmark Node instead.
- Loopback = software ceiling. Real-LAN numbers must be taken with the in-app bench (`/#/bench`) on a phone and recorded with the network (Wi-Fi standard, band, distance, hotspot or router).
- Each change: run `pnpm bench` (sink + `--disk`) and `pnpm bench:browser` before/after with `--tag`, keep only if better beyond run-to-run noise (±5%), and store the JSON in `tests/performance/results/`.
- `pnpm bench --check` compares against `tests/performance/budget.json` (set to ~80% of today's numbers, so noise doesn't fail it but a real regression does).
