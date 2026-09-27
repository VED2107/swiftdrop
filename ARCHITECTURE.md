# SwiftDrop architecture

## 1. Transport choice

| Option | Verdict | Why |
|---|---|---|
| WebRTC DataChannel | rejected | SCTP in userspace: ~20–60 MB/s in Safari, CPU-heavy; ICE host candidates are mDNS-obfuscated and fail on some hotspots/routers; iOS receivers must buffer into a Blob in RAM (multi-GB videos crash the tab). |
| WebTransport | rejected | Not available in iOS Safari. |
| WebSocket for data | rejected | Single TCP stream, message framing overhead, no benefit over HTTP bodies. |
| **HTTP/1.1 chunk bodies to a server on the PC** | **chosen** | Kernel TCP congestion control and buffers, up to 6 parallel connections per host in every browser, binary bodies with zero encoding, native downloads on iOS (disk-streamed), works offline. |

WebSocket is used only for control events (join requests, device presence, progress, offers) and RTT pings on a connection that isn't queued behind uploads.

## 2. Protocol (v1)

- Files are addressed in **1 MiB blocks** — the unit of integrity and resume.
- `POST /api/transfers` — manifest (all files' metadata once). Returns per-file state + base64 bitmaps for resume, or `409` with name conflicts.
- `PUT /api/transfers/:t/files/:f/blocks/:start` — 1–16 contiguous blocks, raw body, `x-sd-hashes` header carries per-block digests. Response header `x-sd-load` = receiver disk pressure (backpressure hint).
- `POST /api/transfers/:t/batch` — many small files: `[u32 headerLen][JSON header][bytes…]`.
- `POST …/complete` — sender's root digest (digest of block digests). Mismatch → receiver discards the file → sender restarts it.
- Error codes are machine-readable; `USER_MESSAGES` maps each to plain language.
- Versioned via `x-sd-protocol` and `protocol: 1` in the manifest. The `Transport` interface in the engine is the seam for a future native TCP/QUIC mode.

## 3. Chunking and parallelism

`AdaptiveController` (pure, unit-tested):
- **Streams:** start 3, probe +1 while throughput rises > 5%; revert to the best level when a probe doesn't pay; re-probe every ~10 s; halve on errors; −1 when the receiver reports disk pressure ≥ 0.85; re-learn when throughput collapses. Cap 6 (browser per-host limit).
- **Chunk size:** targets 250–900 ms per request (grow ×2 if faster, shrink if > 1.8 s). Bounded by memory budget: `streams × chunk ≤ 48 MiB` on iOS, 128 MiB desktop.
- Samples every second from bytes acked; each new level is measured fresh (no smoothing carry-over).

`Planner`: large files split on demand into ranges of the current chunk size (parallel streams pull consecutive ranges of one file; server writes positionally). Files ≤ 512 KiB are packed into ≤ 8 MiB batch frames. Every block is missing → claimed → acked; failures release claims; acked blocks are never re-sent.

## 4. Resume

- Receiver persists `<dest>/.swiftdrop/<tid>.json` (bitmaps + block digests, debounced 1 s, atomic rename) and `.part` files.
- Network drop → engine aborts in-flight requests, pings with backoff (0.4 → 5 s), fetches status, adopts the receiver's bitmap, continues.
- Page reload → the phone stores transfer id + file fingerprints (path, size, mtime) in localStorage; re-selecting the same files reuses the id and file ids → resume.
- PC restart → device tokens are persisted (hashed), transfer state is on disk → phone reconnects and resumes.
- `INCOMPLETE` (receiver missing blocks it once acked, e.g. crash before persist) triggers a resync, not a failure.

## 5. Integrity

Per-block digests computed once on each side while the data is already in memory: **xxh64** by default (WASM, several GB/s — `crypto.subtle` is unavailable on `http://` LAN origins in Safari), **SHA-256** optional. Final per-file root = digest of the block digest list, so no file is ever re-read end-to-end just to hash it. For blocks sent in an earlier session, the sender hashes them locally from the file before completing.

## 6. Security

- Pairing token (128-bit) only in the QR's URL **fragment** (never sent to servers, stripped from the address bar on load); 6-char code from a 31-symbol alphabet; both expire after 5 min and rotate after each pairing.
- Every join needs **explicit approval on the PC**. Pending joins are per-IP limited; code guesses rate-limited per IP and globally.
- Approved devices get 256-bit bearer tokens; stored server-side as SHA-256 only; idle expiry 7 days; "Forget" revokes and disconnects.
- Host role = request from one of the PC's own addresses. Host-only routes: pairing, approvals, settings, folder picker, outbox.
- **DNS-rebinding guard:** `Host` header must be localhost or one of the PC's IPs. **CSRF guard:** `Origin` on writes must match. WebSocket requires the subprotocol and same origin.
- Filenames: NFC, strip separators/control/bidi overrides, escape Windows reserved names, cap length; relative dirs reduced to safe segments; every final path checked to stay inside the destination root.
- Sizes and offsets bounded by the manifest; body length must match the block range; configurable max file size; free-space check before accepting.
- Downloads by plain navigation use HMAC-signed, 15-minute, per-offer tickets. `Content-Disposition: attachment`, `nosniff`, MIME allow-list. Strict CSP on the SPA.

## 7. Windows filesystem

The server writes directly: positional writes into `.part` files, atomic rename into place, original `lastModified` restored (photos keep their capture date in Explorer). Duplicates: metadata-only detection (name exists) with Replace / Skip / Keep both. Folder choice via the native Windows folder dialog (PowerShell `FolderBrowserDialog`), so no File System Access API and no per-file download prompts.

## 8. Expected bottlenecks

1. Wi-Fi airtime — the real ceiling (and shared with everything else on the network).
2. iPhone reading + hashing + Safari request overhead; mitigated by 1–16 MiB chunks and batching.
3. NTFS + antivirus per-file creation cost for tens of thousands of small files.
4. PC → iPhone goes through a local staging copy (loopback, fast) because a web page can't hand the server a file path.
