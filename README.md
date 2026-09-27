# SwiftDrop

Fast file and photo transfer between a phone (**iPhone** or **Android**) and a **Windows PC** over your local Wi-Fi. No accounts, no cloud, nothing to install on the phone.

```
iPhone Safari ──(parallel HTTP chunks over Wi-Fi)──▶ SwiftDrop on the PC ──▶ your folder
```

## Quick start

Requirements: Node.js 20.10+ (24 recommended), pnpm, Windows 10/11.

```powershell
pnpm install
pnpm start          # builds the web app, starts the server on port 8787, opens the browser
```

1. On the PC the page shows a QR code and a 6-character code.
2. On the phone (same Wi-Fi, or connect the PC to the phone's hotspot), scan the code with the Camera app (iPhone) or Camera / Google Lens (Android), or open the shown address and type the 6-character code.
3. Tap **Allow** on the PC.
4. On the phone, tap **Send photos & videos** or **Send files**. Files land in `Downloads\SwiftDrop` (change it with **Change folder**, which opens the normal Windows folder picker).
5. To send PC → iPhone, drop files or folders on the PC page. The phone gets a **Download** / **Download all (.zip)** button (and **Save to Photos** for media).

**Phone can't connect?** Windows asks to allow Node.js through the firewall on first run — allow it on *Private* networks, and make sure your Wi-Fi is set to Private. Or run once as admin:
`powershell -ExecutionPolicy Bypass -File scripts\allow-firewall.ps1`

Internet is not needed. Only the two devices and a router/hotspot.

## Distribution

SwiftDrop has two deliverables:

| | What | Where |
|---|---|---|
| **SwiftDrop.exe** | The app. Local server + web UI in one file; runs on the user's Windows PC. | `pnpm build:exe` → `release/SwiftDrop.exe` (Node single executable, ~90 MB). Publish it on GitHub Releases or any file host. |
| **Landing page** | Marketing + download page (`apps/site`). Static. | Vercel, configured by `vercel.json` at the repo root. |

**Why the app itself can't run on Vercel:** SwiftDrop's server must run on the PC that receives the files — it writes to the local disk, shows the PC's LAN address in the QR code, and phones connect to it over Wi-Fi. A cloud deployment can't reach your disk, would route file bytes through the internet, caps request bodies at ~4.5 MB, and a page served over `https://*.vercel.app` is blocked by browsers from talking to `http://192.168.x.x`. So Vercel serves only the landing page.

### Deploy the landing page on Vercel

1. vercel.com → Add New → Project → import `VED2107/swiftdrop`. Leave *Root Directory* as the repo root; `vercel.json` sets install/build/output.
2. Environment variable `VITE_DOWNLOAD_URL` = the **public** URL of `SwiftDrop.exe`. The repo is private, so its release assets are not publicly downloadable: publish the exe somewhere public (a public releases repo, S3/R2, etc.) and point this at it.
3. Deploy.

### Build the Windows app

```powershell
pnpm build:exe          # release/SwiftDrop.exe
```

Double-click to run: it opens the browser, stores settings in `%USERPROFILE%\.swiftdrop`, and a second launch just reopens the running instance. The exe is unsigned, so SmartScreen warns on first run until it's code-signed.

## Commands

| | |
|---|---|
| `pnpm start` | build web app + run server (production) |
| `pnpm serve` | run server with the existing build |
| `pnpm dev` | server (watch) + Vite dev server on http://localhost:5173 (PC only; test phones against `pnpm start`) |
| `pnpm test` | unit + integration tests (Vitest, real server over loopback) |
| `pnpm test:e2e` | browser end-to-end: pairing + transfer (Playwright) |
| `pnpm typecheck` | strict TypeScript for everything |
| `pnpm bench [--disk] [--sha256] [--large]` | engine + server loopback benchmark |
| open `/#/bench` in the app | in-browser benchmark over the real network (dev dashboard) |

Environment: `SWIFTDROP_PORT` (8787), `SWIFTDROP_DEST`, `SWIFTDROP_MAX_FILE_BYTES`, `SWIFTDROP_LOG` (`debug|info|warn|error`), `SWIFTDROP_NO_OPEN=1`. `SWIFTDROP_E2E=1` is a **test-only** mode (a second browser on the PC acts as the phone) — never use it on a real network.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full decision record. Short version:

- **Why not WebRTC:** Safari's DataChannel (SCTP in userspace) tops out far below Wi-Fi speed, burns CPU, relies on flaky mDNS ICE on hotspots, and — the deal-breaker — iOS can only save received WebRTC data from an in-memory Blob, which dies on multi-GB videos. WebTransport isn't in iOS Safari.
- **What instead:** the PC *is* the endpoint. A small Node server on the PC serves the web app and receives chunks over plain HTTP from the phone. TCP gives kernel congestion control and buffering; Safari opens up to 6 parallel connections; Node writes blocks positionally straight to disk. PC → iPhone uses ordinary downloads, so Safari's download manager streams to the Files app with no RAM limit.
- **Data path never leaves the LAN.** The server runs on the PC; there's no cloud component at all.

### Monorepo

```
apps/
  server/            Node HTTP + WebSocket server: pairing, auth, receive store, ZIP64 streaming, static SPA
  web/               Vite + React + Tailwind SPA (PC and phone UI)
packages/
  protocol/          Wire protocol v1: Zod schemas, constants, batch frame codec, error codes → human messages
  transfer-engine/   Transport-agnostic sender: planner, adaptive controller, speed meter, job, queue
  crypto/            xxh64/SHA-256 block hashing (WASM), tokens, codes, base64url
  shared/            Filename/path sanitization, formatting, bitset, logger
tests/
  integration/       Real server + real engine over loopback: resume, corruption, security, ZIP, restart
  performance/       Loopback benchmark CLI
  e2e/               Playwright: phone + PC browsers, pairing, transfer, byte-compare
```

There is no separate `ui` package: the UI has one consumer, so a package would only add ceremony. The engine never imports React, so a native companion app can reuse `protocol` + `transfer-engine` with a TCP/QUIC `Transport`.

## Performance (measured)

Loopback on the dev machine (Windows 11, Node 24). Loopback removes Wi-Fi from the picture, so this is the software ceiling; on real Wi-Fi the radio is the limit (typically 30–120 MB/s).

| Scenario | Engine → server, verify-only | Engine → server, to disk |
|---|---|---|
| 100 MB file | 199 MB/s | 173 MB/s |
| 1 GB file | 277 MB/s | 257 MB/s |
| 1,000 photos × 3 MB | 266 MB/s | 224 MB/s |
| 1,000 files × 200 KB | 165 MB/s | 116 MB/s |
| 10,000 files × 50 KB | 70 MB/s (1,400 files/s) | 45 MB/s (~900 files/s) |

Through the real UI in Chromium (phone emulation, 849 MB mixed set): **~280 MB/s average**. Peak process RSS stays ~200–500 MB regardless of file size (inputs stream; nothing is held whole).

Bottlenecks found by measuring, and fixed:

1. **Chromium `fetch` with a `Uint8Array` body uploads at ~20 MB/s; the same bytes as a `Blob` go ~350 MB/s.** Chunk bodies are now Blobs: browser path went **18 → 222 MB/s**.
2. **Small files to disk were serialized** behind a naming lock (stat + mkdir + create per file, NTFS/antivirus latency). Now: atomic `O_EXCL` name reservation, cached directories, 16 parallel creates per batch: **27 → 45 MB/s** for 10k × 50 KB.
3. Adaptive controller initially "found" gains from its own smoothing lag and over-probed streams; fixed by re-measuring from scratch at each new level (covered by tests).

## Android

Works in Chrome on Android over the same LAN: pairing (QR or typed code), sending photos/videos/files with the same parallel, resumable engine, and downloads from the PC (they land in *Downloads*, and photos show up in the gallery). Android's photo picker returns originals. Chrome also pauses background tabs, so keep SwiftDrop open while sending; it resumes where it stopped. Covered by a Playwright test using a Pixel user agent.

## Honest platform notes

- **iOS suspends web pages** in the background or when locked. SwiftDrop holds a screen Wake Lock while sending and resumes automatically when you return; it cannot keep sending while locked.
- The iOS photo picker may **convert HEIC → JPEG and compress video**. In the picker tap *Options → Current* for originals, or use *Send files* from the Files app.
- iOS can't write into arbitrary folders from a web page. PC → iPhone files go to **Files → Downloads**; media can go to Photos via the share sheet only when small enough for iOS to hold in memory (≤ 400 MB per batch).
- Folders: dragging whole folders works on Windows (Chrome/Edge/Firefox). iOS Safari has no folder picker.
- After a page reload the browser forgets the selected files (it never persists `File` objects). Pick the same items again and the transfer resumes where it stopped.
- Not yet tested on physical iPhones in this environment: the test matrix below needs a real device. Automated tests use WebKit-UA Chromium emulation.

### Manual test matrix (to run on hardware)

Windows Chrome/Edge ↔ iPhone Safari/Chrome; 5 GHz and Wi-Fi 6 routers; iPhone hotspot; pull Wi-Fi mid-transfer; background the tab; 10 GB video; 5,000 photos; duplicates; cancel; resume after reload. Use `/#/bench` on the phone for numbers.
