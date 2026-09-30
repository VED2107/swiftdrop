# SwiftDrop app (Flutter)

The native SwiftDrop app for iOS, Android, Windows, macOS and Linux. Plan and status: `docs/FLUTTER_MIGRATION.md` (§14 for Phase 2); design: `docs/FLUTTER_UI_PLAN.md`.

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
| `flutter run -d windows --dart-define=SWIFTDROP_DEMO=true` | scripted demo devices and transfers for design work (invented numbers, never in a release) |
| `flutter analyze` / `flutter test` | static analysis / widget tests |
| `flutter build windows --release` | release build |
| `cd ../../packages/swiftdrop_core && dart analyze && dart test` | core checks |
