# Flutter migration: architecture assessment

Status: **Phase 1 (analysis) only. Nothing is implemented yet.** This document is the plan the later phases follow. Every claim about the current code comes from reading it at `712638e`; every claim about a platform that this Windows machine cannot test is marked **verify on device**.

Baseline at the time of writing: `pnpm test` 66/66 passing (7 files), Flutter 3.29.3 / Dart 3.7.2 installed, Windows + Android toolchains present, **no macOS host** (iOS and macOS builds cannot be produced or signed from this machine).

---

## 1. Current architecture

```
                         ┌──────────────────────── Windows PC ─────────────────────────┐
 iPhone / Android        │  apps/server (Node, single exe via SEA, Inno Setup installer) │
 Safari / Chrome  ──HTTP─┤    app.ts     routes, CSRF + DNS-rebinding guards           │
 apps/web SPA            │    auth.ts    pairing token/code, approvals, device tokens   │
 (served by the PC)      │    store.ts   receiver: verify blocks, .part files, resume   │
      │  WebSocket ──────┤    hub.ts     control events (presence, progress, offers)    │
      │                  │    picker.ts  native Windows file/folder dialogs (PC → phone)│
      │                  │    zip.ts     streamed ZIP for multi-file downloads          │
      │                  └──────────────────────────────────────────────────────────────┘
      │
 phone A (p2p.html, HTTPS static) ══ WebRTC DataChannel ══ phone B (p2p.html)      ← no PC
```

### 1.1 Packages (TypeScript, pnpm workspace)

| Package | Role | Lines | Quality |
|---|---|---:|---|
| `packages/protocol` | Zod schemas, constants (`BLOCK_SIZE` 1 MiB, 16 blocks max per request, 512 KiB small-file threshold, 8 MiB batches), batch frame codec, error codes + plain-language messages | 301 | Stable, versioned (`protocol: 1`) |
| `packages/transfer-engine` | `TransferJob` (scheduler, read-ahead, reconnect loop, telemetry), `Planner` (missing → claimed → acked per block, small-file batching), `AdaptiveController` (hill-climbing streams + latency-targeted chunk size under a memory budget), `SpeedMeter`, `TransferQueue`, `Transport` interface + `HttpTransport` | ~1,400 | Pure, clock-injected, unit-tested; measured on loopback |
| `packages/peer` | `PhoneTransport` interface, `DataChannelTransport` (binary framing, bufferedAmount backpressure), `PeerTransport` (engine `Transport` as RPC over a link, re-attachable), `PeerReceiver` (same verification rules as the PC store, `SinkFactory`/`StateStore` seams), signal codec (deflate + base64url for QR), `describePath` (host/srflx/relay + private-address proof) | ~1,300 | Tested in memory and over real Chromium WebRTC |
| `packages/crypto` | hash-wasm xxh64 / SHA-256 block hashing + root digest, tokens, codes, base64url | 132 | Small, correct |
| `packages/shared` | `Bitset` (base64 for resume), filename/relDir sanitising, format helpers | ~200 | Small, correct |

### 1.2 Apps

| App | Role |
|---|---|
| `apps/server` | The PC side. Node HTTP server + WebSocket hub, receiver store, pairing/auth, native Windows pickers, ZIP streaming. Packaged as a single exe + installer (`scripts/build-exe.mjs`, `build-installer.mjs`). |
| `apps/web` | React SPA served by the PC (host screen with QR, phone screen with composer/offers/progress) plus `p2p.html`, a standalone HTTPS page for phone ↔ phone with OPFS storage and an in-page QR scanner. |
| `apps/site` | Marketing site (Vercel), "contact sheet" design, grease-pencil red `#d8322a`. |

### 1.3 Protocol as it runs today

Control plane (JSON) and data plane (raw binary) are already separated. Two transports implement the same engine interface:

| Engine call | HTTP (phone → PC) | Peer RPC (phone → phone) |
|---|---|---|
| `create(manifest)` | `POST /api/transfers` → status + bitmaps, or `409` conflicts | `req op=create` (waits for Accept on the receiver) |
| `status(id)` | `GET /api/transfers/:t` | `req op=status` |
| `putBlocks(1–16 blocks, digests)` | `PUT …/files/:f/blocks/:start`, digests in `x-sd-hashes`, load hint in `x-sd-load` | `req op=blocks len=N` + `0x02` data frames |
| `putBatch(frame)` | `POST …/batch` `[u32 len][JSON header][bytes]` | `req op=batch len=N` + data frames |
| `complete(file, root)` | `POST …/complete` | `req op=complete` |
| `cancel`, `ping` | `DELETE`, `GET /api/ping` | `req op=cancel`, `req op=ping` |

Peer wire frames: `0x01 | UTF-8 JSON` control, `0x02 | u32 reqId | u32 offset | bytes` data, ≤ 64 KiB per DataChannel message, send paused above 1 MiB buffered.

Integrity: per-1-MiB-block digests (xxh64 default, SHA-256 optional) computed while the bytes are in memory anyway; per-file root = digest of the digest list, so no file is re-read to verify it. Resume: receiver bitmaps + block digests persisted (debounced 1 s, atomic rename) next to `.part` files; any drop → `ping` → `status` → adopt bitmap → send only missing blocks. `INCOMPLETE` triggers a resync rather than a failure.

### 1.4 What is measured, and what is not

From `PERFORMANCE_AUDIT.md` (one Windows laptop, loopback, two processes):

- Node engine → Node receiver: 1 GB at 526–556 MB/s (sink), 447 MB/s to NVMe; 10k × 50 KB at 345 MB/s sink / 95 MB/s disk. Receiver RSS bounded ≤ 267 MB regardless of file size.
- **Chromium upload ceiling ~40 MB/s** on Windows loopback, unexplained. This is why PC → phone now serves natively picked files in place (1 GB offer ready in 18 ms instead of ~27 s).
- NTFS small-file creates: ~3,200/s per folder (Defender on).
- **Not measured anywhere:** real Wi-Fi, any phone, WebRTC throughput between two phones, iOS OPFS limits. `docs/PHONE_TO_PHONE.md` lists these as unverified.

Implication for the migration: we have strong software-ceiling numbers and zero real-device numbers. The Flutter phases must produce the first real ones before any transport decision is treated as settled.

---

## 2. What the current design cannot do (why a native app)

| Limit | Cause | Native app fixes it? |
|---|---|---|
| iPhone/Android need the PC for anything but the p2p page | browser can't listen for connections | yes: every device can be a receiver |
| No local discovery | browsers can't do mDNS/NSD | yes: Bonjour / NSD / DNS-SD |
| Phone ↔ phone needs two QR scans (offer + answer) | WebRTC signaling through the camera | yes for app ↔ app (discovery + one confirmation); QR stays as fallback |
| iOS browser receiver stores in OPFS, then must share out | no filesystem access from Safari | yes: write straight to app Documents / Photos |
| Browser upload ceilings (6 connections/host, ~40 MB/s Chromium loopback, 64 KiB SCTP frames) | browser networking stack | yes: `dart:io` sockets, kernel TCP, large frames |
| JS stops when Safari is backgrounded | browser lifecycle | partly: Android foreground service / user-initiated job; iOS still suspends (see §8) |
| Safari photo picker may transcode HEIC/video | PHPicker defaults in Safari | yes: request the original file representation |

What the browser path does that a native app cannot replace: **zero install on the guest phone**. That is a real product advantage (scan a QR, done). The migration keeps it (§6.4).

---

## 3. Proposed architecture

```
┌───────────────────────────── apps/swiftdrop (Flutter) ─────────────────────────────┐
│  UI (widgets, lib/design/*)   no business logic, reads view models only            │
│        ↓                                                                            │
│  Application layer (Riverpod providers / notifiers)                                 │
│    DiscoveryController · PairingController · TransferCoordinator · History · Settings│
│        ↓  snapshots at ≤ 10 Hz over a SendPort; commands the other way             │
├──────────────────────────── engine isolate(s) ─────────────────────────────────────┤
│  packages/swiftdrop_core (pure Dart, no Flutter import)                             │
│    protocol   · wire types, codecs, error codes (mirrors packages/protocol v1)      │
│    engine     · TransferJob, Planner, AdaptiveController, SpeedMeter, Queue         │
│    receiver   · Receiver (store.ts + receiver.ts rules), FileSink, StateStore       │
│    rpc        · PeerRpc (PeerTransport semantics), Link interface, framing          │
│    security   · device identity, pairing, SAS, pinned TLS                           │
│    transport  · TransportManager + TcpLink, HttpTransport (to the existing PC       │
│                 server), WebRtcLink (adapter; implementation lives in the app)      │
├──────────────────────────── platform layer ────────────────────────────────────────┤
│  packages/swiftdrop_platform (Flutter plugin, federated per OS)                     │
│    file sources: content:// (Android), security-scoped URLs + PHAsset (iOS/macOS)   │
│    file sinks:   MediaStore / SAF (Android), Documents + PHPhotoLibrary (iOS)       │
│    discovery:    Bonjour / NSD / DNS-SD via bonsoir                                 │
│    background:   foreground service / user-initiated job (Android),                 │
│                  background task + continued processing (iOS, verify)               │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

Rules:

1. `swiftdrop_core` has no `package:flutter` import and runs under `dart test` on the host. That is how it stays testable, benchmarkable from the CLI, and independent of widgets.
2. The engine runs in a **background isolate**. Hashing, file reads/writes and socket I/O never share an event loop with animation. The UI receives a snapshot stream (the same shape as today's `JobSnapshot`), never chunk events. This is the Dart version of the "two processes" lesson in the performance audit.
3. Platform code only exposes **byte sources and sinks with positional access**, discovery, and lifecycle. It never sees the protocol.

### 3.1 The transport abstraction

The brief's conceptual `TransferTransport { connect, sendManifest, sendChunk, receiveChunk, sendControl, close }` already exists as `PhoneTransport` in `packages/peer/src/channel.ts`, and the engine-facing `Transport` sits above it. The Dart port keeps both layers because they solve different problems:

```dart
/// Byte link between two devices. TCP, WebRTC DataChannel, in-memory for tests.
abstract interface class Link {
  Future<void> connect();
  Future<void> sendControl(ControlMessage m);      // small JSON, never queued behind data
  Future<void> sendChunk(int reqId, int offset, Uint8List bytes); // awaits backpressure
  Stream<ControlMessage> get control;
  Stream<DataFrame> get data;                       // receiveChunk
  Future<void> close();
  int get maxFrameBytes;
  bool get isOpen;
  LinkPath get path;                                // local / p2p / relayed, for the UI badge
}

/// What the engine needs (today's `Transport`). PeerRpc implements it over any Link;
/// HttpTransport implements it against the existing PC server.
abstract interface class EngineTransport {
  Future<CreateResult> create(Manifest m);
  Future<TransferStatus> status(String transferId);
  Future<Load> putBlocks(String t, String f, int start, Uint8List body, Uint8List digests, CancelToken c);
  Future<Load> putBatch(String t, Uint8List frame, CancelToken c);
  Future<String> complete(String t, String f, String root);
  Future<void> cancel(String t);
  Future<void> ping();
}
```

`sendManifest` stays a control message (it is one), exactly as in the TS code.

### 3.2 Mapping the requested message set onto the existing protocol

The brief lists `SESSION / MANIFEST / ACCEPT / FILE_START / CHUNK / FILE_COMPLETE / TRANSFER_COMPLETE / PAUSE / RESUME / CANCEL / ERROR`. The existing request/response protocol already covers these with proven resume semantics; replacing it with a new message set would throw away tested behaviour for naming. Mapping:

| Requested | Existing mechanism | Change needed |
|---|---|---|
| SESSION | none on the peer link today (the QR carries a session id) | **new** `hello` exchange: protocol version, device id, capabilities, then authenticated (see §5) |
| MANIFEST | `create` request | none |
| ACCEPT | `create` response (after the person taps Accept) or `DECLINED` | none |
| FILE_START | implicit: first `blocks` for a file | none (explicit start adds a round trip and nothing to verify) |
| CHUNK | `blocks` / `batch` request + `0x02` frames; the response is the ACK | none |
| FILE_COMPLETE | `complete` with root digest | none |
| TRANSFER_COMPLETE | sender-side when the planner is finished | **new** `done` notification so the receiver can close history without inferring it |
| PAUSE / RESUME | sender-local state (stop issuing requests); resume = `status` + adopt bitmap | **new** optional `pause` notification so the receiver shows "Paused by sender" instead of "Waiting" |
| CANCEL | `cancel` request | none |
| ERROR | `res ok=false code=…` with the shared `ERROR_CODES` | none |

Result: **protocol v1 stays; v1.1 adds `hello`, `done`, `pause`.** Old peers ignore unknown notifications, so the browser p2p page keeps working.

### 3.3 Framing on TCP

DataChannel messages have boundaries; TCP does not. `TcpLink` frames as:

```
u8 type | u32 BE length | payload
  type 0x01  control   payload = UTF-8 JSON
  type 0x02  data      payload = u32 reqId | u32 offset | bytes
```

No 64 KiB SCTP limit: data frames can carry up to 1 MiB, cutting per-frame overhead ~16×. Backpressure comes from the socket (`Socket.flush()` / `IOSink` done futures) with an explicit high-water mark, same contract as `bufferedAmount` today. Parallelism: the controller's "streams" become pipelined requests on one connection first; a pool of 2–4 TCP connections is only added if the Wi-Fi benchmark shows one connection under-uses the link (the same rule `PHONE_TO_PHONE.md` applies to multiple DataChannels).

---

## 4. Code that stays, gets ported, or gets replaced

| Code | Decision | Reason |
|---|---|---|
| `packages/protocol` constants, schemas, error codes, batch frame | **Port to Dart, byte-compatible** | The contract between every SwiftDrop build. Shared JSON test vectors (§11) keep TS and Dart identical. |
| `Planner`, `AdaptiveController`, `SpeedMeter`, `TransferQueue` | **Port line-for-line** | Pure logic with unit tests; the controller encodes measured lessons (probe windows ≥ 6 completions, memory budget). Port the tests with it. |
| `TransferJob` | **Port**, replace `Blob.slice().arrayBuffer()` with positional `RandomAccessFile` reads | Same scheduler, read-ahead and reconnect loop. |
| `HttpTransport` | **Port** | Lets the Flutter phone app talk to the existing Windows server unchanged: app users get native file access against today's PC. |
| `PeerTransport` / `PeerReceiver` / framing | **Port** as `PeerRpc` / `Receiver` over the `Link` interface | Same RPC, same verification; the Link underneath becomes TCP or WebRTC. |
| `apps/server/src/store.ts` rules | **Merge into the Dart `Receiver`** | Positional `.part` writes, atomic rename, `lastModified` restore, duplicate policy, free-space check: every native receiver needs them. |
| `packages/shared` sanitising + `Bitset` | **Port** | Filename rules must match on every OS (Windows reserved names apply when receiving on Windows). |
| `packages/crypto` hashing | **Replace implementation, keep algorithms** | xxh64 in Dart (64-bit ints are native on VM/AOT) with an FFI fallback if the benchmark shows it below disk speed; SHA-256 via BoringSSL-backed `package:cryptography` native or FFI. Digests must match hash-wasm byte-for-byte. |
| Signal codec + `describePath` | **Port** | Needed for Flutter ↔ browser WebRTC and for the path badge. |
| `apps/server` (Node) | **Keep through Phase 9**, then decide (§6.4) | It is the only thing serving no-install browser guests today. |
| `apps/web` host SPA + `p2p.html` | **Keep**. Stays the no-install guest experience. | Not replaced by Flutter web: Flutter web cannot open sockets either, so it would inherit every browser limit and add bundle weight. |
| `apps/site` | **Keep**. Gains download links in Phase 10. | Marketing surface, different design world. |
| WebSocket hub, HMAC download tickets, CSP | Stay in the Node server | Browser-specific concerns. |

Estimated Dart port of the core: ~3,500 lines + tests, most of it mechanical.

### 4.1 Why the core is Dart, not Rust or the existing TypeScript

| Option | For | Against | Verdict |
|---|---|---|---|
| **Pure Dart core** | one language with the UI; `dart test` on CI; isolates for parallelism; `dart:io` sockets are kernel TCP; AOT on every target | pure-Dart hashing may be slower than native; porting cost | **chosen**, with FFI for hashing only if measured necessary |
| Rust core via `flutter_rust_bridge` | fastest hashing/IO; one binary for all OSes | second toolchain on every build machine including iOS; FFI boundary for every chunk event; the engine's cost is I/O and network wait, not CPU (audit: sender hash 3%, receiver main thread 52% idle) | not now; revisit only if Phase 8 profiling shows CPU-bound hot paths |
| Keep TS engine in an embedded JS runtime | no port | no sockets, no file APIs, a JS engine per platform | rejected |

---

## 5. Security design

Local Wi-Fi is not trusted. Today's model (browser guests) is PC-approval + bearer tokens + DNS-rebinding/CSRF guards; the peer page relies on QR possession + WebRTC DTLS. The native app needs an identity model because devices will find each other by discovery, not only by QR.

**Device identity.** Each install generates an Ed25519 (or P-256) key pair in the platform keystore (Keychain / Android Keystore / DPAPI / libsecret) and a self-signed TLS certificate for it. Device id = SHA-256 of the public key.

**Transport.** `TcpLink` runs over TLS 1.3 (`SecureSocket`, BoringSSL: AES-GCM with hardware acceleration, so encryption should not become the throughput limit; **benchmark** in Phase 8). Both sides present certificates; validation is by **pinned fingerprint**, not a CA.

**First pairing, three ways, all ending in explicit confirmation:**

| Path | How the peer is authenticated |
|---|---|
| QR | QR carries `{v, sid, host candidates, port, cert fingerprint, one-time secret, expiry}`. Scanner connects, checks the fingerprint, proves the secret inside TLS. Never contains file data. Expires in 5 min, single use. |
| Discovery tap | TLS with unknown certs, then both screens show a 6-digit **short authentication string** derived from both fingerprints + both nonces (numeric comparison, as in Bluetooth pairing). User confirms they match on both devices. |
| Browser guest | Unchanged: existing QR token + PC approval flow. |

**After pairing.** Fingerprints are stored as trusted devices; reconnects authenticate by pin, no prompt. **Every transfer still needs Accept on the receiver** unless the receiver turned on auto-accept for that specific trusted device (off by default).

**Replay / expiry.** `hello` carries a fresh nonce per side and is bound to the TLS channel (exporter keying material), so a recorded handshake can't be replayed; QR secrets are single-use; session ids expire; transfer ids are random 96-bit.

**WebRTC path.** DTLS encrypts it; the application still authenticates the peer by including the DTLS fingerprint from the SDP in the signed `hello`. Without this, a malicious signaling path could swap SDP.

Full threat model and wire details go in `docs/SECURITY.md` (Phase 3).

---

## 6. Transport selection

### 6.1 Candidates

| Transport | When | Expected strength | Unknowns |
|---|---|---|---|
| `TcpLink` (TLS over LAN) | both sides run the native app | kernel TCP, large frames, no browser caps | real Wi-Fi throughput vs WebRTC |
| `WebRtcLink` (`flutter_webrtc`) | one side is the browser p2p page; or TCP can't connect but ICE can | interop with no-install guests; ICE tries every candidate pair | libwebrtc SCTP speed on phones, binary size (+~10–20 MB per app) |
| `HttpTransport` | app ↔ existing Node PC server | works with today's installed PCs | none, already measured |

### 6.2 `TransportManager`

```
peer known? ── from discovery (native app) ──► try TcpLink to advertised addresses (parallel, 2 s)
            │                                     ok → "Direct · Local network"
            │                                     fail ↓
            ├── from QR ──► QR says native? → TcpLink to QR addresses → else WebRtcLink
            ├── browser guest ──► WebRtcLink (p2p.html) or HttpTransport (PC server)
            └── nothing connects ──► plain-language diagnosis: different network,
                                     client isolation, VPN, firewall (Windows prompt)
```

Selection is by **capability first, then measurement**: the choice is recorded per device pair in history with measured throughput, and Phase 8 decides the default ordering from benchmark data rather than assumption. UI states stay two: **Direct · Local network** (both endpoints proven private/link-local, same proof `describePath` uses today) or **Direct · P2P**. There is no relay, so there is no third normal state.

### 6.3 Networks where nothing local works

Guest Wi-Fi with client isolation blocks both TCP and WebRTC host candidates. The honest answer is a hotspot (one phone hosts, the other joins), which works offline. Wi-Fi Direct / Multipeer Connectivity / Nearby Connections could bypass the router, but none of them work across iOS ↔ Android. Recorded as a later investigation, not promised.

### 6.4 The Windows side during and after migration

Today's Windows product = Node server + browser UI + no-install phones. The Flutter Windows app adds native pairing, discovery and app ↔ app transfer. Two options for the no-install browser guest after Phase 9:

1. Keep shipping the Node server inside the Flutter Windows installer as a helper process (no code churn, two runtimes).
2. Re-host the HTTP API in `dart:io` `HttpServer` inside the Flutter app (one runtime, reimplements `app.ts` + `auth.ts` security guards).

Decision deferred to Phase 9 with benchmark data (Node's receiver path is measured at 447–556 MB/s; a Dart re-host has to match it). Until then, nothing in `apps/server` is deleted.

---

## 7. Platform requirements

### 7.1 Android

| Need | API | Notes |
|---|---|---|
| Pick photos/videos | Android Photo Picker (`ACTION_PICK_IMAGES`), backported via Play services | Returns `content://` URIs. **Avoid `file_picker`'s default copy-to-cache** for large files. |
| Pick files/folders | SAF `ACTION_OPEN_DOCUMENT` / `ACTION_OPEN_DOCUMENT_TREE` | Tree URI + `DocumentFile` walk for folders with relative paths. |
| Stream reads without copying | `ContentResolver.openFileDescriptor(uri, "r")` → detach fd → Dart opens `/proc/self/fd/<n>` with `RandomAccessFile` | Positional reads straight from Dart; no bytes over the platform channel. **Verify** on API 26–35. |
| Save received files | `MediaStore` insert with `IS_PENDING=1`, write via fd, clear pending on completion; or SAF tree chosen by user | Pictures/Movies/Download collections; relative paths via `RELATIVE_PATH`. |
| Discovery | NSD (`NsdManager`) through `bonsoir` | `CHANGE_WIFI_MULTICAST_STATE` + multicast lock only for raw multicast fallback. |
| Background | Android 14+: **user-initiated data transfer job** (`JobInfo.Builder#setUserInitiated`); older: foreground service type `dataSync` with a progress notification | Android 15 caps `dataSync` FGS at 6 h/day; the UIDT job is the intended API for this exact use. |
| Notifications | `POST_NOTIFICATIONS` runtime permission (13+) | progress + incoming-transfer notifications |
| QR | CameraX + ML Kit (`mobile_scanner`) | |

### 7.2 iOS

| Need | API | Notes |
|---|---|---|
| Local network | `NSLocalNetworkUsageDescription` + `NSBonjourServices` = `_swiftdrop._tcp` | First connection triggers the system prompt; denial must be detected and explained. |
| Discovery | `NWBrowser` / `NWListener` (Bonjour) via `bonsoir` | Raw UDP broadcast/multicast needs the `com.apple.developer.networking.multicast` entitlement, granted by Apple on request. Plan does not depend on it. |
| Pick photos/videos | `PHPickerViewController` with `preferredAssetRepresentationMode = .current` and `loadFileRepresentation` | Returns a temp copy the app must move before the callback ends; prevents HEIC → JPEG transcoding. Large videos cost a copy on disk (not RAM). Alternative: PhotoKit `PHAssetResourceManager` streaming with full library permission. **Verify** copy time for a 5 GB video. |
| Pick files | `UIDocumentPickerViewController` (`asCopy: false`) | Security-scoped URLs: `startAccessingSecurityScopedResource` then positional reads with `RandomAccessFile` on the path. |
| Save received files | App `Documents/SwiftDrop/…` with `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` so they show in Files; photos/videos: `PHAssetCreationRequest` from the file URL (add-only permission) | Written positionally, never held in RAM. |
| Open / share | `UIDocumentInteractionController`, share sheet | |
| Receive from other apps | Share Extension (later phase) | Extension memory limit ~120 MB; it hands file URLs to the app, never loads bytes. |
| QR | AVFoundation (`mobile_scanner`) | |
| Background | see §8 | |

### 7.3 Desktop

| Need | Windows | macOS | Linux |
|---|---|---|---|
| Pick files/folders | `file_selector` (native dialogs, returns paths: **no upload hop**, preserving the in-place PC → phone win) | same, sandbox bookmarks for the Mac App Store build | same (portal on Flatpak) |
| Drag and drop | `super_drag_and_drop` / `desktop_drop` (paths) | same | same |
| Discovery | DNS-SD (Windows 10 1809+ native `DnsServiceBrowse`) via `bonsoir` | Bonjour | Avahi (must be running; detect and explain) |
| Firewall | inbound rule prompt on first listen; installer can pre-register (existing `allow-firewall.ps1`) | Application firewall prompt | usually open; ufw note |
| Tray / background | `tray_manager`, keep running when window closed | menu bar extra | tray (AppIndicator) |
| Notifications | `local_notifier` / `flutter_local_notifications` | same | libnotify |

---

## 8. iOS lifecycle: what actually happens

| Event | Behaviour | Design response |
|---|---|---|
| App backgrounded mid-transfer | ~30 s of execution via `beginBackgroundTask`, then suspended; sockets die | Request the background task on every transfer; on suspension the peer sees `NETWORK`, both sides keep resume state; on return the engine reconnects and resumes from the bitmap. |
| iOS 26 continued processing | `BGContinuedProcessingTask` lets a user-started task continue in the background with system progress UI | **Investigate and verify on device** in Phase 6. If it covers local socket transfers, it is the best path; if not, document. Not assumed. |
| Phone locked | same as backgrounded; screen-on keeps it alive | Offer "Keep screen on during transfer" (idle timer disabled while the transfer screen is visible). |
| Wi-Fi changes | socket errors, addresses change | reconnect loop re-resolves the peer via discovery (by device id, not IP) and resumes. |
| App killed | nothing runs | resume state is on disk on both sides; next launch lists "Paused transfer" with Resume. |
| Low storage | write fails | free-space check before Accept; `DISK_FULL` message. |

This is a limitation, not a bug, and the UI must say it plainly ("Keep SwiftDrop open until the transfer finishes"), matching product principle 4.

---

## 9. Migration phases

Each phase ends with: tests green, `dart analyze` / `flutter analyze` / `tsc` clean, build for the platforms available on this machine, benchmark where relevant, one coherent commit.

| Phase | Deliverable | Exit criteria |
|---|---|---|
| **1. Analysis** | this document + `docs/FLUTTER_UI_PLAN.md` | reviewed and approved |
| **2. Project setup** | `apps/swiftdrop` Flutter app (Android, iOS, Windows, macOS, Linux targets), `packages/swiftdrop_core` (pure Dart), Dart pub workspace, CI script; decide Flutter upgrade (installed 3.29.3 is 18 months old) | empty app builds on Windows + Android; `dart test` runs |
| **3. Shared protocol + transport interfaces** | Dart port of protocol, planner, controller, speed meter, bitset, sanitiser, hashing; `Link`, `EngineTransport`, `PeerRpc`, `Receiver`, in-memory link; shared cross-language test vectors; `docs/ARCHITECTURE.md`, `docs/SECURITY.md` | ported unit tests pass; TS and Dart produce identical digests, bitmaps, batch frames |
| **4. Desktop** | `TcpLink` + TLS pinning, Windows/macOS/Linux file sources and sinks, `HttpTransport` to the existing server, design system + desktop shell | Windows ↔ Windows over LAN; Flutter Windows app ↔ existing Node server; 1 GB and 10k-file runs with RSS bounded |
| **5. Android** | content-URI sources, MediaStore/SAF sinks, UIDT job / FGS, NSD, QR | Android ↔ Windows and Android ↔ Android on real devices, interrupted + resumed |
| **6. iOS** | PHPicker/document sources, Documents/Photos sinks, lifecycle handling, Bonjour permission flow | needs a Mac + devices; iPhone ↔ Android, iPhone ↔ iPhone, iPhone ↔ Windows |
| **7. Discovery + pairing** | bonsoir everywhere, SAS pairing, trusted devices, QR pairing, `WebRtcLink` for browser guests; `docs/NETWORKING.md` | discovery with no internet on router and on hotspot |
| **8. Performance** | benchmark matrix (§10), TCP vs WebRTC per platform, connection pool decision, hashing path decision; `docs/BENCHMARKS.md` | every number recorded with hardware + network |
| **9. Real-device validation** | full device × network matrix, `docs/PLATFORM_LIMITATIONS.md`, Node server keep/re-host decision | pass/fail table filled from devices, not emulators |
| **10. Packaging** | signed AAB/APK, IPA, MSIX or Inno installer, notarised DMG, AppImage | release builds install on clean machines |

Phases 4 and 5 can overlap once Phase 3 lands. Phase 6 is blocked on macOS hardware.

---

## 10. Performance plan

Target path (unchanged in spirit from today, now native on both ends):

```
disk ─► bounded read-ahead (RandomAccessFile, 1–16 MiB) ─► xxh64 per 1 MiB block ─► TLS/TCP (≤ 1 MiB frames)
      ─► receiver: bounded reassembly (≤ 96 MiB) ─► verify block digest ─► positional write to .part ─► rename
```

- **Memory**: in-flight bytes bounded by the controller budget (48 MiB mobile, 128 MiB desktop, as today) plus receiver reassembly cap. RSS must not grow with file size; measured in every benchmark.
- **Copies**: read into one `Uint8List`, hash in place, write the same buffer to the socket; receiver reads frames into a preallocated request buffer. `TransferableTypedData` for isolate hand-offs so they are moves, not copies.
- **Isolates**: engine isolate owns sockets and files; if hashing shows up above ~10% of request time, a small hashing isolate pool (sized by measurement, not by core count).
- **Small files**: batching (≤ 8 MiB frames) stays; receiver creates in parallel across folders (NTFS serialises per directory, measured).
- **What gets measured separately** (the brief's split): disk read, disk write, hashing, TCP LAN, WebRTC LAN, end-to-end; plus CPU, RSS, time-to-first-byte, resume overhead. Scenarios: 100 MB, 1 GB, 5 GB, 10,000 small files, mixed camera roll.
- **Rule from the audit**: sender and receiver in separate processes; ±5% noise band; keep a change only if it wins beyond it; JSON results committed. No marketing claim ("fastest", "10×") without a controlled comparison in `docs/BENCHMARKS.md`.

---

## 11. Testing plan

| Level | What | Where it runs |
|---|---|---|
| Unit (Dart) | protocol codecs, planner, controller (port the ±25% noise test), bitset, sanitiser, hashing, resume state, duplicate policy, state machines | `dart test`, every commit |
| Cross-language | JSON/binary vectors generated by the TS code (`tests/vectors/*.json`): manifests, batch frames, digests, bitmaps, signal payloads. Both suites assert against them. | `pnpm test` + `dart test` |
| Integration (Dart) | sender ↔ receiver over in-memory link and over real loopback TCP+TLS: multi-file, 1 GB, drop + resume, corruption, cancel, duplicates, folders | `dart test`, desktop CI |
| Interop | Flutter app ↔ Node server (HTTP); Flutter ↔ `p2p.html` in Chromium (WebRTC) | Phase 4 / 7 |
| Platform | Android, iOS, Windows, macOS, Linux device runs from a checklist | Phase 9 |
| Network | same Wi-Fi, congested Wi-Fi, drop mid-transfer, different subnets, no internet, hotspot, Wi-Fi switch | Phase 9 |
| Existing | `pnpm test`, Playwright e2e keep passing throughout | every commit |

---

## 12. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| No macOS host | iOS/macOS phases can't be built, signed, or tested here | acquire Mac + Apple Developer account before Phase 6; keep iOS code paths compiled in CI on a hosted macOS runner |
| iOS background suspension | long transfers stop when the user leaves the app | resume is already the core design; investigate `BGContinuedProcessingTask`; say it in the UI |
| Pure-Dart hashing too slow | CPU-bound sender on phones | benchmark first; FFI to native xxh64/SHA-256 is a contained swap |
| `flutter_webrtc` size / SCTP speed | +10–20 MB, maybe slower than TCP | only used for browser interop and fallback; measured in Phase 8 |
| Plugins copying files to cache (`file_picker`, `image_picker`) | 5 GB videos duplicated on disk, slow start | own platform plugin for sources; plugins only for dialogs that return paths |
| Discovery blocked (client isolation, mDNS filtered, Avahi missing) | "no devices nearby" | QR fallback always visible; diagnosis copy per cause |
| Two receivers diverge (Node store vs Dart receiver) | subtle incompatibility | shared vectors + interop tests; one protocol version constant |
| Scope: 5 platforms, native plugins, security | long timeline | phase gates; desktop + Android first because they can be tested here |
| Flutter 3.29.3 is 18 months old | missing current APIs (e.g. backdrop grouping, recent Impeller fixes) | upgrade decision at the start of Phase 2 |

---

## 13. Decisions needed before Phase 2

1. **Core language**: pure Dart (recommended) vs Rust via FFI.
2. **Flutter version**: upgrade to current stable at Phase 2 (recommended) or stay on 3.29.3.
3. **Repo layout**: `apps/swiftdrop` + `packages/swiftdrop_core` + `packages/swiftdrop_platform` inside this monorepo (recommended) vs a separate repo.
4. **State management**: Riverpod (recommended: testable providers, no codegen required) vs Bloc.
5. **Apple hardware**: when a Mac and developer account are available for Phase 6.
