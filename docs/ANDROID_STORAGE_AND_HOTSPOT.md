# Android storage, phone-to-phone hotspot, updates (1.1.0)

## 1. Where received files go (Android)

```
network ─► private staging  <app support>/staging/.swiftdrop/<tid>/<fid>.part   (positional writes, resumable)
        ─► every block verified, root digest checked by the receiver
        ─► PlatformBridge.publish(...)  ─► Kotlin StorageBridge
              image / video / audio ─► MediaStore  Pictures|Movies|Music/SwiftDrop/<folders>   (IS_PENDING=1 until complete)
              everything else       ─► Downloads/SwiftDrop (MediaStore.Downloads)  or the folder picked once (SAF tree)
        ─► fsync (files ≥ 4 MiB) ─► staging `.part` deleted
```

- Incomplete data never reaches a public place: MediaStore entries stay pending until the bytes are in; the SAF document is
  deleted on failure. A failed publish keeps the `.part` and the resume state.
- Original bytes, name, MIME type and file modification time are kept. No recompression, no resize. (MediaStore's own
  `date_modified` column is re-stamped by the provider; the file's mtime is the original.)
- The folder is chosen with the system picker (opens at Documents), persisted with a persistable URI grant, and checked at
  every launch; if the grant disappeared the app falls back to Downloads/SwiftDrop.
- Duplicates follow the existing policy (keep both / replace / skip), checked against the real destination.
- Permissions: none on Android 10+. Android 7-9 request `WRITE_EXTERNAL_STORAGE` (declared `maxSdkVersion=28`).
- The engine isolate cannot hold a MethodChannel, so `PortBridge` (engine) ⇄ `BridgeHost` (UI isolate) ⇄ `MainActivity.kt`.
  `swiftdrop_core` stays pure Dart (`boundaries_test`).

Trade-off: publishing is one local streamed copy (`FileChannel.transferTo`) after verification, so a very large file needs
roughly twice its size free for a moment. Writing straight into the MediaStore file descriptor would avoid it but breaks the
"verify, then publish" guarantee and resume across restarts.

## 2. Phone-to-phone over a hotspot

Installed apps already talk native TCP (`TcpLink`, parallel lanes, resume, per-block integrity); WebRTC is only the browser
`/p2p/` page. So this was not a transport problem.

**Root cause (found by reading the address path, then confirmed on Android 17):** the QR carried exactly one address,
`endpoint.addresses.first`, ranked by *interface name* ("wlan/wl/en" first). A hotspot owner's mobile-data link
(`rmnet_data*`, CGNAT `10.x` / `100.64.x`) and its hotspot interface (`ap0` / `swlan0`) both look like "private, not Wi-Fi",
so they tied and the order came from the OS: the mobile-data address could be put in the QR, which the other phone can never
reach. Android also keeps no `Network` object for the hotspot a phone *hosts*, so the name was the only hint.

Fixes (`NetBridge.kt`, `net_ifaces.dart`, `engine_runtime.dart`, `connect_code.dart`):

1. Interfaces are classified with `ConnectivityManager` (wifi / ethernet / cellular / vpn) and "private address on an interface
   with no Network" = hotspot. Cellular and VPN addresses are never offered.
2. The QR lists every reachable network (`l=` parameter, up to 3 more, old apps ignore it).
3. The scanner races all of them (own-subnet first, 250 ms stagger, 4 s each) and refuses a host that answers as a different
   device id.
4. Network changes (Wi-Fi, hotspot AP broadcasts, VPN) refresh the QR immediately; with a VPN up the process is bound to the
   Wi-Fi network so LAN traffic is not captured by the tunnel.
5. Settings → Network details shows what is offered and the connected path; `[NET]` lines are logged in debug builds.

Not done: TLS on the LAN link (still plain TCP, every transfer needs an explicit Accept).

## 3. Updates

`GithubUpdater` asks `api.github.com/repos/VED2107/swiftdrop/releases/latest`, shows the notes, downloads the platform asset
(APK / `Setup.exe`), checks size and the SHA-256 GitHub reports, then hands it to the installer:
Android through a `FileProvider` + system installer (one-time "install unknown apps" switch), Windows by running the same Inno
Setup installer silently over the existing install, which closes the app and starts the new version. Updates only install over
a build signed with the same key (the 1.1.0 APK is signed with the 1.0.0 key). Settings → About shows the running and the
latest version, and the automatic check can be turned off.

## 4. Measured (Android 17 emulator, adb-forwarded TCP, so numbers are tunnel-bound)

| Case | Result |
|---|---|
| 12 mixed files (jpg, png, mp4, mp3, pdf, zip, folder) | 12/12 verified; images/video/audio in MediaStore, `is_pending=0`; documents in Downloads/SwiftDrop; md5 identical |
| Custom folder (SAF), restart app, send again | lands in the chosen folder, `archive (1).zip` for the duplicate |
| 1 GiB file | verified, md5 identical, 127 s (8.5 MB/s through the tunnel), app PSS ≈ 270 MB (debug) |
| 300 × 100 KB photos | 300/300 verified in 30 s (~10 files/s, provider-bound on the emulator) |

Not measured (no hardware here): two real phones over a hotspot, iPhone ⇄ Android hotspot, Windows ⇄ Android on a real LAN,
HEIC/MKV/5 GB video on a real Gallery app, Android 7-9.
