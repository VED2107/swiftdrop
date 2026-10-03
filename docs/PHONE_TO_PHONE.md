# Phone ↔ Phone (web, direct, no PC)

Status (2026-10-04): one-QR pairing, wire format v2, bidirectional sessions and the app-style UI are implemented and covered by unit, integration and two-browser WebRTC tests. **Not yet measured on real phones**: every number below is from Chromium on one Windows machine and is labelled as such. Real-device runs (iPhone ↔ iPhone, iPhone ↔ Android, phone ↔ desktop browser) are still owed.

Requirement: phone A sends files directly to phone B. No byte of file data touches a PC, a cloud relay, Vercel, the rendezvous mailbox, or any server.

```
           SIGNALING ONLY (sealed SDP, ~1 KB per message, never file data)
     ┌── QR on the sender's screen ──┐        ┌── rendezvous mailbox (ntfy protocol) ──┐
     │   offer + 128-bit secret      │        │   AES-GCM ciphertext, random topics    │
     ▼                               │        ▼                                        │
 📱 sender ═════════════════ WebRTC DataChannel (DTLS) ═════════════════ 📱 receiver
           DATA PLANE: manifest, file bytes, digests, acks, resume state — both directions
```

## 1. Flow

1. **Sender** taps Send. The file picker opens; while it is up, the WebRTC offer is built (ICE gathered).
2. Files picked → the QR appears at once: `https://<host>/p2p.html#o=<offer>&k=<secret>`.
3. **Receiver** taps Receive and scans it, or points the iPhone Camera at it (Safari opens the link and the page acts as the receiver). Nobody scans back.
4. The receiver's answer is sealed with a key derived from the secret and posted to the mailbox; the sender, listening, completes the handshake. DataChannel opens.
5. Receiver sees "iPhone wants to send 3 files" → Accept. The sender's first 1 MiB request goes out immediately (measured 4–14 ms after the accept reaches the sender).
6. The connection stays up as a session: **either phone can send** (Send more, Send files back, Select files on the connected screen), including both directions at once.

No internet (hotspot without uplink, or `?signal=off`): the mailbox is unreachable, so the receiver shows a reply QR and the sender taps **Scan reply**: one extra scan, everything else identical. The sender only offers that path when the mailbox failed.

Drop: the phone that showed the QR re-dials through the mailbox every 8 s (fresh offer to the `guest` box, answer back in the `host` box); the new channel is attached to the same transfer, which asks the receiver for its bitmaps and sends only what's missing. Manual fallback: "Show a new code" / "Scan again".

### Why a mailbox, and what it can see

A browser cannot open a socket to another phone, and WebRTC needs both DTLS fingerprints and ICE credentials to cross in both directions; one QR carries only one direction. So the answer needs a path back. Options were a second QR (the old flow), or a relay for ~1 KB of SDP. The mailbox is that relay:

- Protocol: the publish/subscribe subset of [ntfy](https://ntfy.sh): `POST /<topic>` and `GET /<topic>/json?since=…`. Default `https://ntfy.sh` (CORS-enabled, no account); override with `VITE_SIGNAL_URL`; self-host with `apps/signal` (`pnpm --filter @swiftdrop/signal start`, ~150 lines, in memory, 4 KiB body cap, 10 min TTL, 16 messages per topic).
- Topics and key are derived from the QR's 128-bit secret (SHA-256 with distinct labels). The server sees two random topic names and `1.<base64url(iv ‖ AES-GCM ciphertext)>`; not SDP, not IPs, not device names. A message sealed with another secret fails to decrypt and is dropped; a replayed answer doesn't match the live session id.
- It cannot carry files: messages are signaling objects (`{kind: offer|answer, signal}`), bodies are capped, and the data path is the DataChannel. No STUN/TURN is configured, so ICE can only pick local candidates.
- CSP allows exactly the configured mailbox origin (`apps/web/vercel.json`, and the PC server for `p2p.html`).

## 2. Audit of the previous implementation (v1)

| Question | Finding |
|---|---|
| Why did iPhone selection feel slow? | Mostly the iOS picker itself: the photo picker exports/transcodes assets before `change` fires, and the JS can't see or shorten that. On top of it v1 built **thumbnails** (`URL.createObjectURL` + `<img>` decode of every image ≤ 30 MB) in the selection grid, and the flow made you pick → tap "Show code" → wait for ICE → scan → scan back before any byte moved. |
| Where were files copied? | Sender: `blob.slice().arrayBuffer()` (needed), then **a new frame + copy per 64 KiB** for the 9-byte header. Batches: per-file `arrayBuffer()` → copy into a frame → wrapped in a `Blob` → `PeerTransport` called `blob.arrayBuffer()` **again**. Receiver: copy into reassembly buffer (needed), then **`bytes.slice()`** before posting to the OPFS worker. |
| Where was hashing? | Per 1 MiB block, streaming, while sending (xxh64, wasm, GB/s). Never a whole-file pre-hash. Not a bottleneck (debug panel: 1.3–2.2 GB/s). |
| Did the manifest block? | The manifest is metadata only (names, sizes); building it is microseconds. It waits for Accept by design. |
| Where did WebRTC stall? | 1 MiB send buffer with a 256 KiB low mark; raw measurements show a deeper buffer helps (§4). |
| Storage limits? | Small files: **open + write + close per file, each awaited as a separate worker round trip** (3 messages per file). Measured 1.4 ms per 10 KB file just for OPFS handle creation. |
| Why ~11–17 MB/s? | That is the browser's DataChannel itself. With **no SwiftDrop code at all**, two separate Chromium processes blasting frames reach 15–23 MB/s on this machine (§4). v1 reached ~85% of the single-process ceiling. |
| Receiver-only / one-QR possible without breaking signaling? | Yes: signaling was already transport-agnostic (`PeerSession.offer/answer/accept` take strings). Only the return path for the answer was new (the mailbox). |

## 3. Pipelines

**v1**
```
tap Send → picker (iOS export/transcode) → thumbnails decode → "Show code" → ICE gather → QR
→ receiver scans → reply QR → sender scans → DataChannel → manifest → Accept
→ read 1 MiB → hash → per-64 KiB frame alloc+copy → send (1 MiB buffer)
→ receiver: copy into body → hash → slice() copy → worker → write (per small file: 3 round trips)
```

**v2 (now)**
```
tap Send → picker opens; offer + ICE gathered in parallel
→ picked: File references only (no read, no thumbnail, no hash) → QR on screen
→ receiver scans → sealed answer via mailbox → DataChannel warm
→ manifest (metadata) → Accept → first 1 MiB request starts at once (4–14 ms)
→ read 1–4 MiB slice → hash blocks → send views of the buffer (no copy), 8 MiB send buffer,
  bodies serialized, next request read+hashed while this one is on the wire (bounded 32 MiB)
→ receiver: copy into body → verify digests → transfer buffer to the OPFS worker (no copy)
  → positional write; small files: whole batch frame → one append to a pack file
→ per-file root digest check on completion; bitmaps persisted for resume
```

### Data plane v2 (`packages/peer/src/channel.ts`)

- Control: **string** messages (compact JSON). File bytes: **binary** messages carrying nothing but body bytes; the type of the message tells them apart, so data needs no header and goes out as `subarray` views.
- One body at a time, each right after its own `req`; the receiver attributes binary messages to requests by order. A request aborted mid-body ends with `{t:"abort", id, sent}` in the same ordered stream.
- Bidirectional: each phone runs a `PeerTransport` (its outgoing requests) and a `PeerReceiver` (the other phone's requests) on the same channel.
- Backpressure: wait while `bufferedAmount + next > 8 MiB`, resume on `bufferedamountlow` (2 MiB) with a 50 ms timer fallback. Stall count and time are exported (`stats`).
- Message size: `min(peer max-message-size, 64 KiB)`.
- Version: signal payload `v: 2`. A v1 page scanning a v2 code (or the reverse) gets "The other phone has a different version of SwiftDrop open. Reload the page on both phones."

### Controller (`PEER_CONTROLLER`)

2→4 pipelined requests, 1→4 MiB per request, 32 MiB in-flight budget (sender reads + receiver reassembly), windowed probing (judged over ≥ 6 completions, never per chunk). The first request is a single 1 MiB block so bytes move at once.

### Receiver storage

- Large files: one OPFS file each, positional `SyncAccessHandle` writes in a dedicated worker; the reassembly buffer is transferred, not copied.
- Small files (batch frames, ≤ 512 KiB each): appended to `swiftdrop/<transfer>/pack` with an append-only `pack.index`; saving returns disk-backed `File` slices of the pack. Measured 0.4 vs 1.4 ms per 10 KB file.
- IndexedDB is not used for file data.

## 4. Measurements (Chromium on one Windows PC, loopback; not phones)

Raw DataChannel ceiling, no SwiftDrop code, two separate Chromium processes (`tests/performance/raw-datachannel.ts`, results in `tests/performance/results/raw-datachannel-2proc.json`):

| message | 1 MiB buffer | 4 MiB | 16 MiB |
|---|---|---|---|
| 16 KiB | 14.7 MB/s | 8.3 | 12.3 |
| 64 KiB | 15.8 | 19.9 | **22.6** |
| 256 KiB | 15.9 | 18.3 | 17.1 |

Full app, same harness as the 2026-09-28 baseline (two contexts in **one** Chromium process, so sender and receiver share one network thread), 256 MiB, OPFS receiver (`SD_P2P_BENCH=1 npx playwright test tests/e2e/p2p-bench.spec.ts`; `results/p2p-chromium-loopback-v2.json`):

| | v1 (2026-09-28) | v2 |
|---|---|---|
| 256 MiB single file | 10.4–11.9 MB/s | 12.3–13.3 MB/s |
| accept → first byte | not measured | 4–14 ms |
| 1,000 × 10 KB | not measured | 3.5–3.6 s (~280 files/s) |
| in-flight memory | ≤ 16 MiB + 1 MiB buffer | ≤ 32 MiB + 8 MiB buffer (measured peak 3–6 MiB) |

Small-file profile (debug panel): sender file reads ~3 MB/s summed across parallel reads, i.e. ~3 ms per `File.arrayBuffer()` call in this Chromium; storage 13 MB/s while busy after the pack change (5 MB/s before). The per-file read cost is the browser's.

## 5. Browser and iOS limits (what can't be optimized from JS)

- **DataChannel throughput** is bounded by the browser's SCTP stack (small ~1.2 KB packets, each DTLS-encrypted, on one network thread). Measured 15–23 MB/s raw in Chromium; Safari's number must come from devices. More channels or peer connections didn't raise it in earlier measurements.
- **iOS photo picker**: the export/transcode happens before the page gets `File` objects. SwiftDrop's input has **no `accept` filter**, so iOS offers Photo Library / Take Photo / Choose Files in one sheet and (per WebKit's behaviour when HEIC isn't excluded) should hand over originals; **verify on device** whether HEIC and video arrive untranscoded.
- **No background**: Safari suspends the page when locked or backgrounded; the channel dies. Wake Lock keeps the screen on while connected; drops resume.
- **Saving**: no folder access on iOS; received files live in OPFS until saved via the share sheet or download. Large-video save-out behaviour: **verify on device**.
- **Secure context**: OPFS, camera and Wake Lock need https; `p2p.html` is a static page for an https host.
- **Per-file read cost** (§4) limits tiny-file rate; batching hides the network side, not the read side.

## 6. Debug panel

`?debug=1` shows: connection state, selected candidate pair (type/protocol), RTT, message size; sender channel MB/s, `bufferedAmount` (and peak), stalls, file-read and hash MB/s, streams × chunk and controller decision, ack latency p50/p95, stage times; receiver channel and storage MB/s; in-flight memory; picker → link, accept → first send, first ack, first file done. Never rendered without the flag.

## 7. Files

| Path | Role |
|---|---|
| `packages/peer/src/channel.ts` | wire v2, backpressure, link stats |
| `packages/peer/src/rendezvous.ts` | sealed mailbox client (ntfy protocol) |
| `packages/peer/src/signal.ts` | signal codec v2, pair links |
| `packages/peer/src/receiver.ts` | verification, resume, owned writes, batch fast path |
| `packages/transfer-engine/src/job.ts` | parallel small-file reads, current file, first-byte timings |
| `apps/signal` | self-hostable rendezvous (SDP only) |
| `apps/web/src/p2p/pairing.ts` | host (QR) / guest (scan) pairing, re-dial |
| `apps/web/src/p2p/P2PApp.tsx`, `p2p.css`, `Debug.tsx`, `history.ts` | app UI, state machine (`data-state` on the root), debug panel, recent transfers |
| `apps/web/src/p2p/opfs*.ts` | OPFS worker sink, pack file |
| `tests/e2e/p2p.spec.ts` | one QR via mailbox, in-app scanner + warm second transfer, send-back, offline reply, debug panel |
| `packages/peer/src/peer.test.ts`, `tests/integration/rendezvous.test.ts` | protocol, abort, batches, bidirectional, mailbox crypto |
