# SwiftDrop app (Flutter)

The native SwiftDrop app for Android and Windows 1.0.0, with iOS, macOS and Linux project files maintained for parity work. Plan and status: `docs/FLUTTER_MIGRATION.md`; design: `docs/FLUTTER_UI_PLAN.md`.

```
lib/design/    design system: tokens, theme, LiquidGlass, components, icons, motion
lib/app/       Riverpod providers, router, adaptive shell
lib/screens/   Home, Transfers, Devices, Settings (+ debug design gallery at /gallery)
```

Business logic lives in `packages/swiftdrop_core` (pure Dart). Screens use only `lib/design/` tokens; a test fails on raw colours, durations, font sizes, radii or icon-package imports in `lib/screens` and `lib/app`.

## Commands (run in this folder)

| | |
|---|---|
| `flutter run -d windows` | run on Windows |
| `flutter run -d android` | run on Android |
| `flutter run -d windows --dart-define=SWIFTDROP_DEMO=true` | scripted demo devices and transfers for design work (invented numbers, never in a release) |
| `flutter analyze` / `flutter test` | static analysis / widget tests |
| `flutter build apk --release` | Android release APK (`build/app/outputs/flutter-apk/app-release.apk`) |
| `flutter build windows --release` | Windows release build |
| `cd ../../packages/swiftdrop_core && dart analyze && dart test` | core checks |

## Pairing by QR

The receiver shows one QR (Receive, or Connect → Show my code). On Android, Connect opens on **Scan receiver QR**: the sender scans once and connects. The code is `http://<ip>:<web-port>/#p=<browser token>&v=1&a=<ip:port>&n=<name>&d=<id>` (or `swiftdrop://connect?v=1&a=…` without the browser host): an iPhone Camera opens the served web page, another SwiftDrop app reads `a` and dials it natively. `readScannedCode` (`lib/app/connect_code.dart`) rejects non-SwiftDrop codes, newer versions (`v`), and browser phone-to-phone (`/p2p/`, `#o=`) codes, which the app can't answer. Debug logs are prefixed `[QR]`, `[PAIR]`, `[PERMISSION]`.
