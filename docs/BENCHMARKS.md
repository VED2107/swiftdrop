# SwiftDrop benchmarks

Rules (from `PERFORMANCE_AUDIT.md` §7): sender and receiver in **separate processes**; real files on disk; results reported with hardware, OS, runtime, transport and file set; a change is kept only if it wins beyond run-to-run noise (±5–10% on this laptop); no marketing claim without a row here.

**Everything below is loopback on one laptop.** Loopback measures the software ceiling (engine, socket stack, disk), not Wi-Fi. Real-network numbers (phone ↔ phone, phone ↔ PC, Wi-Fi 5/6, hotspot) are Phase 8/9 work and don't exist yet.

Machine: Intel i5-10300H (4C/8T), 17 GB RAM, NVMe (NTFS, Windows 11 25H2, Defender on).

## Native Dart engine (Phase 3)

Dart 3.13.4, AOT (`dart compile exe`), `packages/swiftdrop_core/bin/bench.dart`. Integrity xxh64. The receiver runs in a separate process (spawned by the sender).

### Primitives (`bench.exe primitives`)

| | MB/s |
|---|---:|
| xxh64, pure Dart (block hashing, 256 MiB in memory) | 3,952–4,181 |
| SHA-256, `package:crypto` | 79–83 |
| file read, async `readInto`, 16 MiB | 1,729–2,014 |
| file read, sync `readIntoSync`, 16 MiB | 4,178 |
| file write, async `writeFrom`, 1 / 4 / 16 MiB calls | **10 / 41 / 160** |
| file write, sync `writeFromSync`, 1–16 MiB | ~3,100–3,300 |
| file write, `IOSink` (`openWrite`) 16 MiB adds | 1,360 |

Conclusions: xxh64 in pure Dart is never the bottleneck (no FFI needed). SHA-256 via `package:crypto` is slow; it stays optional (xxh64 is the default); an FFI/BoringSSL path is a later option if someone needs SHA-256 speed. **Async `RandomAccessFile` writes on Windows cost milliseconds per call**, so the engine uses synchronous file calls on its own isolates.

### Link and RPC (scratch tools in `packages/swiftdrop_core/tool/`)

| Experiment | MB/s |
|---|---:|
| `RawSocket` write loop, 1 MiB frames | 209–246 |
| `Socket` (IOSink) 1 MiB adds | 855–887 |
| TcpLink sender → plain byte counter | 611–871 |
| plain framed sender → TcpLink reader, queue-and-copy reader | 253 |
| … reader copying into a preallocated frame | 533 |
| … reader forwarding data frames as views of socket chunks (kept) | 684 |
| pipelined RPC, 1 × 16 MiB / 5 × 16 MiB / 12 × 1 MiB in flight | 302 / 323 / 576 |
| **parallel connections, one isolate each side (2 GiB)**: 1 / 2 / 4 / 8 | **276 / 406 / 502 / 533** |

Event-loop utilisation during a 1 GiB single-connection transfer: sender 10%, receiver 8–9%. The isolates are mostly **waiting on per-socket I/O**, not computing, so parallel connections (each on its own isolate) are what scale; more compute isolates would not.

### End to end, 1 GiB file, loopback TCP

| Configuration | receiver | MB/s | sender peak in flight | peak RSS (sender / receiver) |
|---|---|---:|---:|---:|
| first working version (RawSocket link, async writes) | disk | 211 | 80 MiB | 228 / 216 MiB |
| sync writes | disk | 221 | 80 MiB | 243 / 209 MiB |
| Socket link + streaming reader, 1 connection | disk | 184–192 | 96 MiB | 178–211 / 144–167 MiB |
| same | discard | 224–256 | | |
| **4 lanes** (4 connections, 4 isolates per side) | discard | **389** | | |
| **4 lanes** | **disk** | **294** | 112 MiB | 343 / 171 MiB |
| 8 lanes | discard | 374 | | |

Memory stays bounded by the controller budget (desktop 128 MiB in flight) whatever the file size; the 256 MiB transfer in the test suite grew RSS by 74 MiB, and the 1 GiB runs sit in the same range.

For comparison, the Node engine on the same machine (`PERFORMANCE_AUDIT.md`): 447 MB/s disk, 526–556 MB/s discard, one process each side. **The Dart path is not yet as fast on loopback.** The measured gaps are Dart's per-socket I/O on Windows and the disk path below; lanes close part of it.

### Many small files (10,000 × 50 KB)

| Configuration | files/s | MB/s |
|---|---:|---:|
| first version (async file calls) | 221 | 11 |
| 4 lanes | 315 | 16 |
| sync file calls, no per-file flush, 4 lanes (kept) | 376–377 | 19 |
| 4 lanes, discarding receiver (sender ceiling) | 2,672 | 134 |
| receiver with a 4 / 8-isolate file-writer pool | 206 / 160 | (removed) |

Per-file disk operations from Dart (`tool/small_files.dart`): create + write + close 798–841 files/s serial; with a flush 401–490; rename 1,745–1,943; a 1/2/4/8-isolate writer pool 472/486/493/515 (no scaling). **Open gap:** Node reaches 1,567 files/s end to end (and ~3,200 creates/s in parallel) on this disk. Next candidate: Win32 `CreateFileW`/`WriteFile` through FFI, measured before it's adopted (Phase 8).

## Decisions taken from these numbers

- xxh64 stays pure Dart; SHA-256 stays optional.
- File I/O in the engine and receiver is synchronous (they run on their own isolates).
- TcpLink uses `Socket` with a streaming, copy-free reader.
- **Native transfers use parallel lanes: 4 on desktop by default, 2 planned on phones** (memory), each an isolate with its own connection, spread by least outstanding work. The request window scales with lanes; the in-flight memory budget doesn't.
- Rejected, measured: RawSocket link, per-4-MiB flushing, smaller request shapes as a fix, a file-writer isolate pool.

## Reproduce

```
cd packages/swiftdrop_core
dart compile exe bin/bench.dart -o build/bench.exe
build/bench.exe primitives
build/bench.exe loopback --mb 1024 [--lanes 4] [--sink null]
build/bench.exe loopback --mb 0 --small 10000 --lanes 4
```
