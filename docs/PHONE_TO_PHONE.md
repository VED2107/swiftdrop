# Phone ↔ Phone (direct, no PC)

Status: **core implemented, not yet verified on real iPhones.** Automated tests cover the protocol (in-memory channel) and a real WebRTC DataChannel transfer between two Chromium pages. Everything marked **verify on device** below is an iOS behavior this repo cannot measure without two phones.

Requirement: phone A sends files directly to phone B. The PC may be switched off. No byte of file data touches the PC, a cloud relay, Vercel, or a signaling server.

```
                 SIGNALING ONLY (SDP + ICE, ~1 KB, no file data)
          ┌──────────── QR on screen, scanned by the other phone ───────────┐
          │                                                                 │
      📱 phone A ════════════════ WebRTC DataChannel ════════════════ 📱 phone B
                 DATA PLANE: manifest, chunks, hashes, acks, resume state
```

## 1. Current transfer engine, as it relates to transport

`packages/transfer-engine` is transport-agnostic already. `TransferJob` owns everything that matters for speed and correctness and only talks to this interface (`transport.ts`):

| `Transport` method | What the engine uses it for |
|---|---|
| `create(manifest)` | send the manifest once; receive per-file state + resume bitmaps (or conflicts) |
| `status(id)` | after any drop: adopt the receiver's bitmap, resend only what's missing |
| `putBlocks(id, file, start, body, hashes)` | 1–16 contiguous 1 MiB blocks + per-block digests; returns a load hint |
| `putBatch(id, frame)` | many small files in one `[u32 len][JSON header][bytes]` frame |
| `complete(id, file, root)` | per-file root digest; mismatch ⇒ receiver discards the file, engine restarts it |
| `cancel(id)`, `ping()` | cancel, reachability probe used by the reconnect loop |

Engine-side pieces reused unchanged: `Planner` (block claims/acks, batching, resume), `AdaptiveController` (concurrency + chunk size under a memory budget), per-block hashing and file roots, the reconnect loop (`ping` → `status` → adopt bitmap → continue), `SpeedMeter`, telemetry, `TransferQueue`.

Today's only implementation is `HttpTransport` (phone → PC server). The receiving logic lives in the Node server (`apps/server/src/store.ts`).

## 2. WebRTC transport boundary

Three layers, each replaceable:

```
TransferJob (unchanged)
   │  Transport interface (unchanged)
   ▼
PeerTransport ─────────── RPC over a PhoneTransport: req/res JSON + binary body frames
   │  PhoneTransport interface
   ▼
WebRTCDataChannelTransport ── one ordered, reliable RTCDataChannel; framing; bufferedAmount backpressure
```

```ts
interface PhoneTransport {
  connect(): Promise<void>;                          // resolves when the channel is open
  sendControl(msg: ControlMessage): Promise<void>;   // small JSON (manifest, acks, status, errors)
  sendChunk(reqId: number, offset: number, bytes: Uint8Array): Promise<void>; // file bytes, awaits backpressure
  sendManifest(reqId: number, manifest: CreateTransfer): Promise<void>;     // a control message, named for clarity
  close(): Promise<void>;
  getBufferedAmount(): number;
  onControl / onChunk / onClose                      // receive side
}
```

- **Wire frames** (every DataChannel message is binary): `0x01 + UTF-8 JSON` for control; `0x02 + u32 reqId + u32 offset + bytes` for data. A request's control message declares its body length; body frames follow on the same ordered channel.
- **Frame size**: `min(pc.sctp.maxMessageSize, 64 KiB)` — large DataChannel messages block the SCTP stream and older Safari/Chrome combinations reject > 64 KiB.
- **Backpressure**: `sendChunk` waits while `bufferedAmount > high` (1 MiB default) for `bufferedamountlow` (`bufferedAmountLowThreshold`, 256 KiB). Never queues unboundedly; Chrome closes a channel whose send queue overflows.
- **One channel** first, as required. Parallel "streams" from the controller become pipelined requests on that channel (they keep the pipe full while the receiver hashes and writes). A multi-channel variant is only worth trying after the device benchmark.
- **`PeerReceiver`** (phone B) answers the same RPCs with the same semantics as the PC server: verify every block digest before marking it received, batch frames, root check on completion, bitmaps for resume. Storage is behind a `SinkFactory` (OPFS on phones, memory in tests).
- **Explicit acceptance**: `create` for an unknown transfer id waits for the person on phone B to tap Accept (with names, count, size, and a storage-quota check). Decline ⇒ `DECLINED`.
- **Direction** `to-peer` is added to the protocol enum so a peer manifest can never be mistaken for a PC upload (the PC server rejects it).

Memory is bounded on both sides: the `PEER_CONTROLLER` budget caps bytes in flight (sender reads + receiver reassembly) at 16 MiB; frames are written to storage per request, never accumulated per file.

## 3. Signaling

Signaling carries only `{type, sdp}` plus a display name and session id — never file data — and is kept out of the transport entirely (`Signaler`-agnostic: the session takes an offer/answer string, however it travelled).

**First mechanism: QR, fully offline.** Non-trickle ICE (wait for gathering to finish; host candidates only, typically < 1 s), SDP deflated with `CompressionStream("deflate-raw")` and base64url-encoded (~500–900 chars → one QR).

1. Phone A (sender) picks files, shows a QR of `https://<app>/p2p.html#o=<offer>`.
2. Phone B scans it — with the in-app scanner, or with the iOS Camera app, which opens the app straight on the offer. B shows its answer as a QR.
3. Phone A taps **Scan reply**, scans B's QR. ICE connects; the DataChannel opens.

Why QR first: no server of any kind, works on a hotspot with no internet, and camera permission has a useful side effect: Safari and Chrome replace host candidates with mDNS `.local` names unless the page holds camera/microphone permission. With the camera granted, the scanning phone's real LAN address is in its SDP, so ICE doesn't depend on mDNS resolution (which some hotspots and routers block).

**Later, optional:** an HTTPS rendezvous that relays only SDP/ICE (short-lived, in memory, no storage of file data), or the PC's existing WebSocket hub when a PC happens to be on. Both plug in above the transport without changing it.

No STUN/TURN servers are configured: the connection is LAN-only by construction. Nothing leaves the local network.

## 4. Is it actually direct and local?

WebRTC does not guarantee a local path. After connecting, `describePath(pc)` reads `getStats()`: the selected candidate pair, both candidates' types (`host`, `srflx`, `prflx`, `relay`), addresses and protocol. The UI says:

- **Direct · Local network** — only when neither side is `relay` and both addresses are private/link-local (RFC 1918, 100.64/10 CGNAT excluded, fc00::/7, fe80::/10) or mDNS `.local` names.
- **Direct · P2P** with the network path shown — not relayed, but the addresses don't prove same-LAN.
- **Relayed** — a TURN relay is in use (not configured today; shown for completeness).

## 5. iPhone receiving and storage constraints

Facts SwiftDrop relies on, with what to check on real devices:

| Topic | Constraint | Design response |
|---|---|---|
| Secure context | OPFS, camera (`getUserMedia`), Wake Lock, `crypto.subtle`, service workers all need HTTPS (or localhost). The PC serves plain `http://192.168.x.x`, so the P2P page can't run from the PC. | `p2p.html` is a standalone static page built separately (`pnpm --filter @swiftdrop/web build:p2p`) and served over HTTPS (Vercel or any static host). It never calls the PC. |
| DataChannel | Supported in iOS Safari 11+. Throughput in Safari is modest (~20–60 MB/s on desktop; **verify on device**). | One reliable ordered channel, 64 KiB frames, bounded buffering. Benchmark before adding channels. |
| Saving files | No `showSaveFilePicker` / File System Access API on iOS. | Receive into the **Origin Private File System** (disk-backed, incremental positional writes, not RAM). Writes go through a dedicated worker with `createSyncAccessHandle()` (Safari 15.2+ / 16.4+ reliable), falling back to `createWritable()`. |
| Getting files out | Files in OPFS are private to the page. | Per file: **Save** = `navigator.share({ files: [opfsFile] })` (Save to Files / Save Image), or a download of the OPFS-backed `File` via an object URL. The `File` is disk-backed; whether iOS copies it into memory for large videos must be **verified on device**. |
| Quota | Safari grants roughly up to 60% of disk per origin (iOS 17+); earlier versions prompt at ~1 GB. | `navigator.storage.estimate()` is checked before Accept; `DISK_FULL` otherwise. `navigator.storage.persist()` requested. |
| Memory | Tabs get killed well before desktop limits. | Never hold a whole file in JS memory; ≤ 16 MiB in flight per side. |
| Background / lock | Safari suspends JS when backgrounded or locked; the DataChannel dies (ICE times out). | Screen Wake Lock while transferring (iOS 16.4+). A drop is resumable: see below. |
| mDNS | Host candidates are hidden behind `.local` names without camera permission. | See §3: the scanning phone has camera permission. **Verify on a hotspot.** |

## 6. Resume and reconnect

- The receiver persists per-transfer state (manifest, block bitmaps, block digests) as JSON in OPFS next to the `.part` data, debounced 1 s — the same model as the PC server.
- Channel drop ⇒ every pending RPC rejects with `NETWORK` ⇒ the engine's existing reconnect loop starts pinging. Re-signaling (a fresh QR round, one tap each) produces a new DataChannel; `PeerTransport.attach(newChannel)` makes `ping` succeed; the engine calls `status`, adopts the receiver's bitmap and sends only what's missing. Blocks already received are never resent.
- Page reload on the receiver: state and partial data survive in OPFS; the same transfer id resumes.
- Page reload on the sender: the existing resume records (file fingerprints in localStorage) re-attach when the same files are picked again.
- Duplicates: each transfer lands in its own OPFS folder, so nothing is overwritten; names are sanitized with the same rules as the PC.

## 7. Files and modules

| Path | Change |
|---|---|
| `packages/protocol` | `to-peer` direction; `DECLINED` error code |
| `packages/peer` (new) | `PhoneTransport` interface, `WebRTCDataChannelTransport`, framing, RPC, `PeerTransport` (engine adapter), `PeerReceiver` + `SinkFactory` + memory sink, signaling codec, `describePath`, `PEER_CONTROLLER` |
| `apps/web/p2p.html`, `apps/web/src/p2p/*` | standalone P2P page: send/receive, QR show + scan, accept, progress, path badge, save; OPFS sink + worker |
| `apps/web/vite.config.ts`, `apps/web/package.json` | multi-page build; `build:p2p` output for an HTTPS host |
| `tests/peer/*` | engine ⇄ receiver over an in-memory channel (bytes, batches, corruption, decline, drop + resume, backpressure) |
| `tests/e2e/p2p.spec.ts` | two Chromium pages, real WebRTC DataChannel, real OPFS, byte-identical file |

## 8. Implementation order

1. **Core** (this change): protocol, `packages/peer`, in-memory tests, real-WebRTC browser test, minimal `p2p.html` (QR both ways, accept, progress, save).
2. HTTPS hosting of `p2p.html` + offline service worker (so the app opens on a hotspot with no internet after the first visit).
3. Real-device verification on two iPhones (and iPhone ↔ Android): throughput, mDNS/hotspot, OPFS limits, save-out of large videos, lock/background recovery. Record results in `PERFORMANCE_AUDIT.md`.
4. Polished pairing UI and re-pair-to-resume flow.
5. Optional signaling paths (HTTPS rendezvous, PC hub when present); multi-channel only if the benchmark says one channel is the limit.
