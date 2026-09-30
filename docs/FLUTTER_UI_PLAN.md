# Flutter app UI plan: screens, components, material system

Status: Phase 2 built the foundation (tokens, glass primitives, shell). **Phase 3 turns it into the product UI**; §13 records the Phase 3 design decisions. Companion to `docs/FLUTTER_MIGRATION.md`. The UI is built in the Flutter app from Phase 4 onward; it never touches the protocol, transports, or engine, only view models exposed by the application layer.

Surface mode: **Operate** (the visitor completes a task). The marketing site stays Persuade and keeps its own world (contact sheet, Archivo, grease-pencil red). The app shares the red and the near-black ground with it, nothing else.

---

## 1. Design read

Native transfer app for everyday phone and desktop users, calm and technical, built on a translucent material system with one red accent that only ever means "your file is moving / arrived intact".

Three things the UI must always answer, on every screen that involves a transfer:

```
who is sending  →  who is receiving  →  how they're connected  →  how far along  →  verified?
```

---

## 2. Tokens (`lib/design/tokens/`)

Carried over from the existing products where they already exist, so the app, the web app and the site stay one family.

| Token set | Values | Source |
|---|---|---|
| `SdColors` | ground `#0E0E10`, ground-raised `#141417`; text `white @ 0.94 / 0.64 / 0.44`; hairline `white @ 0.08`, hairline-strong `white @ 0.14`; **red** `#D8322A`, red-pressed `#A8221A`, red-on-dark text `#FF8A80`, red glow `red @ 0.24`; danger reuses red only with an icon + words (red is never the only signal) | site `--red`, `--red-press`, `--red-print`; web `--mark` |
| `SdType` | system font (SF Pro on Apple, Roboto on Android, Segoe UI Variable on Windows, Cantarell/Inter fallback on Linux); **tabular figures on every number**; display 34/40 semibold −0.6 tracking; title 22/28 semibold; body 16/22; caption 13/18; numeric-hero 56/56 semibold −1.2 tracking, tabular | brief: native font, strong numbers |
| `SdSpace` | 4-pt scale: 4, 8, 12, 16, 20, 24, 32, 40, 48, 64 | web `--s-*` |
| `SdRadius` | one scale, all soft: 10 (chips/inputs), 16 (rows), 22 (cards), 28 (sheets, floating nav), full (pills, round actions). No sharp corners anywhere. | web `--r-*`, shape lock |
| `SdMotion` | curves: `easeOut` = Cubic(0.23, 1, 0.32, 1), `easeInOut` = Cubic(0.77, 0, 0.175, 1), `drawer` = Cubic(0.32, 0.72, 0, 1); durations: press 120 ms, small 180 ms, sheet 320 ms, page 260 ms, exit = 0.7 × enter; springs: `gentle` (damping ratio 0.9) and `settle` (0.8, used only for the completion check) | web `--ease-*`, Emil |
| `SdMaterials` | four glass levels (§3) + `solid` fallback for each | new |
| `SdBreakpoints` | phone < 600, tablet 600–904, small desktop 905–1239, desktop 1240–1599, large ≥ 1600 (logical px, by window width, not device type) | brief |

No screen uses a raw colour, size, radius or duration. A lint (custom `analysis_options` rule or a test that greps `lib/screens/`) enforces it.

---

## 3. Liquid Glass as a material system

### 3.1 Levels

| Level | Used for | Fill | Backdrop blur | Border / highlight | Shadow |
|---|---|---|---|---|---|
| **G1 surface** | grouped settings sections, history day groups | white @ 0.04 | **none** | hairline | none |
| **G2 card** | device cards, transfer card, file list container | white @ 0.07 + 1% red tint when active | **none** (see §3.2) | hairline + top inner highlight (white @ 0.10, 1 px) | soft, tinted, y 12 blur 32 @ 0.35 |
| **G3 floating** | floating tab bar, action dock, desktop sidebar | white @ 0.10 | **real**, sigma 24 + saturation 1.6 | hairline-strong + specular top edge | y 18 blur 48 @ 0.45 |
| **G4 sheet** | incoming transfer, pairing, confirm dialogs | white @ 0.12 | **real**, sigma 32 + saturation 1.8 | hairline-strong + rim light | y 30 blur 80 @ 0.55 + scrim behind |

The QR code is never glass: it sits on an opaque white tile inside a G4 container, full contrast, no blur.

### 3.2 Why G1/G2 don't blur

The environment behind cards is already a soft, low-frequency gradient field. Blurring a blur is visually identical to a translucent fill over it, and costs a full backdrop pass per card. So G1/G2 are translucent fills with highlight + border, and only surfaces that float over **scrolling content** (G3, G4) pay for a real `BackdropFilter`. Budget: **at most two live backdrop filters on screen** (the floating nav + one sheet), shared with `BackdropGroup` where the Flutter version supports it.

### 3.3 The component

```dart
LiquidGlass(
  level: GlassLevel.floating,     // picks fill, blur, border, shadow from SdMaterials
  radius: SdRadius.sheet,         // optional override, still a token
  tint: SdColors.red,             // optional, low alpha, for "active" states
  child: …,
)
```

One implementation. Internals: `ClipRRect` → (`BackdropFilter` with `ImageFilter.compose(blur, ColorFilter saturation)` only for G3/G4) → fill → `CustomPaint` for the gradient border and specular top edge → child. Wrapped in `RepaintBoundary` so a changing child (progress) doesn't repaint the glass.

Degradation, automatic:
- Settings → Appearance → Glass: **Full / Subtle / Off**. Subtle = no backdrop blur anywhere; Off = solid surfaces.
- iOS "Reduce Transparency" and Android/Windows high-contrast → Off.
- Low-end Android (by frame timing in the first seconds, not by model list) → Subtle.

### 3.4 Environment (`AmbientBackground`)

Near-black ground with three very large, very soft light fields: a cool neutral top-left, a faint warm neutral bottom-right, and one red field low behind the primary action. Painted by one `CustomPainter` into a `RepaintBoundary`.

- Idle: fields drift over ~40 s cycles, amplitude a few percent of the screen. Reads as light, not motion.
- Transfer active: the red field brightens and tightens toward the connection line (intensity tween over 600 ms), drift speed unchanged. Energy through light, not through faster movement.
- Reduce Motion, app in background, or battery saver: static frame, no ticker.

---

## 4. Screen hierarchy

```
App shell  (floating glass tab bar on phone · nav rail on tablet · glass sidebar on desktop)
├── Home
│   ├── Nearby devices (DeviceGlassCard × n, live)
│   ├── Primary actions: [Send files] [Receive]
│   └── Recent transfers (3 rows → Transfers)
├── Transfers
│   ├── Active (pinned, prominent)
│   ├── Today / Yesterday / Earlier
│   └── Transfer detail → files, verification, Open / Show in folder / Retry
├── Devices
│   ├── Nearby · Connected · Recently used
│   └── Device detail → Rename, Forget, Connect, Connection details (the only place
│                       that says TCP/WebRTC, addresses, RTT)
└── Settings
    ├── Transfer: Save location · Accept automatically (per trusted device) · Duplicates
    ├── Connection: Local network · Device discovery · QR pairing
    ├── Appearance: Theme · Motion · Glass
    ├── Privacy: Visibility · Permissions · Data handling
    └── About: Version · Open source · Licenses

Flows (pushed over the shell, or as sheets):
├── Send:     pick → Review "Send to …" → Transfer → Complete | Interrupted
├── Receive:  "Ready to receive" (visible as <name>, QR fallback)
├── Incoming: G4 sheet from anywhere → Accept → Transfer (receiving) → Complete
├── Pair:     Connect a device → Show code | Scan code → Confirm 6-digit match → Paired
└── Phone to phone: same Pair flow, entered from Home when no device is nearby,
                    shows the two-device diagram and "No computer needed"
```

Global overlays: incoming-transfer sheet, interruption banner (on any screen while a transfer is reconnecting), drag-and-drop target overlay (desktop).

---

## 5. Key screens (phone)

**Home**
```
SwiftDrop                                  (title, 34 semibold)
Nearby                                     (caption, text-2)
┌───────────────────┐ ┌───────────────────┐
│ [phone icon]      │ │ [laptop icon]     │   DeviceGlassCard (G2), horizontal
│ Ved's iPhone      │ │ MacBook Pro       │   scroll on phone, grid on desktop
│ iPhone            │ │ Mac               │
│ ● Direct · Local  │ │ Available         │
│ [ Send ]          │ │ [ Send ]          │
└───────────────────┘ └───────────────────┘
Recent
  ✓ 24 files · 1.8 GB · to MacBook Pro      TransferGlassRow ×3
  …
╭────────────── action dock (G3) ──────────────╮
│   [ + Send files ]          [ Receive ]       │   thumb zone, above tab bar
╰───────────────────────────────────────────────╯
╭──── Home · Transfers · Devices · Settings ────╮   floating tab bar (G3)
```
Empty state (nobody nearby): the cards area becomes a single G2 panel: "No devices nearby yet", one line on why (same Wi-Fi, SwiftDrop open), and **Connect with a code** (QR pairing). Never a blank row.

**Transfer (sending)**
```
MacBook Pro  ←────●────  This iPhone           ConnectionIndicator: sender → receiver,
Direct · Local network                           a light pulse travels the line
                  ◯  progress ring (68%)
               1.24 GB                           numeric-hero, tabular
               of 1.8 GB
        94 MB/s          1m 12s left             live, 4 Hz, tabular
 24 files · 17 done
            [ Cancel ]                           secondary, destructive confirm
```
**Complete**: ring closes, red check draws in (stroke 260 ms), one soft red ripple (400 ms, once), then "Transfer complete · 24 files · 1.8 GB · Verified" and **Done**. With Reduce Motion: check appears, no ripple.

**Interrupted**: ring freezes at its value, colour drops to text-2, copy: "Connection interrupted. Your transfer is safe. 1.24 GB already transferred. Waiting for MacBook Pro…" with **Resume** (manual retry) and **Cancel**. Never red for this state: nothing is wrong yet.

**Incoming (G4 sheet)**: sender name + icon, "24 files · 1.8 GB", up to 6 thumbnails, free-space line, **Accept** (primary, red) / **Decline**. Accept is focused by default; Decline never hidden.

**Pair: show code**: G4 container, opaque white QR tile ~240 pt, "Scan this with the other device", status line "Waiting for connection…" with a slow breathing dot (stops under Reduce Motion). Toggle to **Scan instead**. After connection: both devices show the same 6-digit code, "Do these match?" **Yes, connect** / **No**.

---

## 6. Desktop adaptation

```
┌─────────────── sidebar (G3) ───┬──────────────── content ─────────────────┬── inspector ──┐
│ SwiftDrop                      │ Nearby                                    │ Active        │
│                                │ [iPhone] [Pixel] [Windows PC] [+ Connect] │ transfer      │
│ ⌂ Home          ⌘1             │                                           │ (live card)   │
│ ⇅ Transfers     ⌘2             │ Recent transfers (table-like rows,        │               │
│ ▭ Devices       ⌘3             │ hover actions: Open · Show · Retry)       │ or: selected  │
│ ⚙ Settings      ⌘,             │                                           │ device detail │
│                                │ Drop files anywhere to send               │               │
│ This PC · visible as "Ved-PC"  │                                           │               │
└────────────────────────────────┴───────────────────────────────────────────┴───────────────┘
 ≥ 1600: three columns · 1240–1599: inspector becomes a slide-over · 905–1239: sidebar collapses to icons
```

- Minimum window 720 × 540. Resizable; layout switches by breakpoint, never by scaling.
- Drag and drop: dropping onto a device card sends to it; dropping elsewhere opens Review with a device picker. The overlay highlights the card under the pointer.
- Keyboard: Ctrl/⌘+O send, Ctrl/⌘+1…4 sections, Ctrl/⌘+, settings, Esc closes sheets, arrow keys move between device cards. **Keyboard-triggered navigation has no animation.**
- Hover states only on pointer devices; context menus on device cards (Send, Rename, Forget) and history rows (Open, Show in folder, Retry, Remove).
- Tray/menu-bar icon: visible name, incoming-transfer notification, quit.

---

## 7. Component architecture (`lib/design/`)

```
lib/design/
  tokens/        colors.dart · typography.dart · spacing.dart · radius.dart · motion.dart
                 materials.dart · breakpoints.dart
  theme/         sd_theme.dart (ThemeData + ThemeExtensions, light theme later) ·
                 platform.dart (glass level resolution, reduce motion/transparency)
  materials/     liquid_glass.dart · ambient_background.dart
  components/
    buttons/     glass_button.dart · primary_action.dart · secondary_action.dart · pressable.dart
    cards/       glass_card.dart · device_glass_card.dart · transfer_glass_card.dart
    navigation/  glass_navigation.dart (tab bar | rail | sidebar by breakpoint)
    sheets/      glass_sheet.dart · confirm_sheet.dart
    progress/    progress_glass.dart (ring + linear) · connection_indicator.dart
    files/       file_glass_row.dart · file_thumbnail.dart · file_grid.dart
    status/      status_pill.dart · path_badge.dart ("Direct · Local network")
    pairing/     qr_code_glass_container.dart · qr_scanner_frame.dart · sas_code.dart
    feedback/    interruption_banner.dart · empty_state.dart · inline_error.dart
  icons/         sd_icons.dart (one icon family, Tabler, one stroke weight; device-type mapping)
  motion/        springs.dart · page_transitions.dart · reduce_motion.dart
lib/screens/     home/ transfers/ devices/ settings/ send/ receive/ pair/ transfer/
lib/app/         router (go_router) · shell · providers (Riverpod view models)
```

Rules:
- Screens compose components; components read tokens; nothing in `screens/` sets a colour, radius, blur, or duration.
- Components take view-model data (`DeviceVm`, `TransferVm`), never engine objects.
- `Pressable` is the single source of press feedback: scale 0.97, 120 ms ease-out, haptic light impact on mobile.

---

## 8. Motion system

| Moment | Motion | Why |
|---|---|---|
| Button press | scale 0.97, 120 ms `easeOut` | feedback |
| Device discovered | card fades in from scale 0.96 + opacity 0, 220 ms, staggered 40 ms | a new thing appeared |
| Device connected | border brightens + red glow fades up, 300 ms | state change |
| QR scanned | viewfinder corners snap inward 120 ms + haptic | confirmation |
| File selected | thumbnail settles from 0.94, 180 ms | feedback |
| Transfer starts | light pulse starts travelling the connection line | the file is moving, and which way |
| Progress | ring/linear driven by transform/stroke painting, interpolated between 10 Hz snapshots | no layout animation |
| File verified | small red check per file row, opacity + scale 0.9→1 | verification is visible |
| Complete | check draw + one ripple, `settle` spring | earned moment, happens rarely |
| Sheet | slide from bottom with `drawer` curve 320 ms, exit 220 ms | spatial |
| Page | 260 ms shared-axis fade + 8 px slide; **none** for keyboard navigation | hierarchy |

Avoided: bounce on everyday controls, particles, looping decoration, anything animating during a transfer except the progress, the connection pulse and the speed number.

Reduce Motion (system setting or in-app): all transforms become opacity-only crossfades ≤ 150 ms, the ambient environment and the connection pulse stop, progress still updates.

---

## 9. Performance budget

- 60 fps floor, 120 fps on ProMotion/high-refresh devices; profiled in profile mode with the performance overlay on a mid-range Android and an iPhone.
- ≤ 2 live backdrop filters; ambient background and each progress widget isolated in `RepaintBoundary`.
- Engine snapshots arrive at 10 Hz from the engine isolate; the speed readout re-renders at 4 Hz; progress interpolates on the UI clock. The UI never receives per-chunk events.
- Thumbnails decoded at display size (`cacheWidth`), generated off the UI isolate; list views lazy (`SliverList`), 10,000-file selections don't build 10,000 widgets.
- Nothing in the UI can block the engine: they are different isolates.

---

## 10. Accessibility

- Dynamic Type / font scale up to 200%: layouts reflow (cards become full-width rows); numbers never truncate.
- Semantics: each device card is one node ("Ved's iPhone, iPhone, connected, direct on local network, button Send"); progress is a live region announced at 10% steps and on state changes, not on every tick.
- Contrast: every glass level has a minimum fill so body text stays ≥ 4.5:1 over the brightest point of the environment; verified with a contrast test on the rendered golden images.
- Touch targets ≥ 44 pt; keyboard focus rings visible on desktop and with hardware keyboards on tablets.
- Red is never the only carrier of meaning: states always have a word and an icon.
- Reduce Transparency / high contrast → solid surfaces (§3.3).

---

## 11. Build order (UI track, from Phase 4)

1. Tokens + theme + `LiquidGlass` + `AmbientBackground`, with a hidden gallery screen and golden tests per component.
2. Shell + navigation (tab bar / rail / sidebar).
3. Home, Devices (on fake view models).
4. Send review, Incoming sheet, Receive.
5. Pairing (show, scan, confirm).
6. Transfer, Complete, Interrupted.
7. Transfers history + detail.
8. Settings.
9. Desktop adaptation pass (breakpoints, keyboard, drag-and-drop, context menus, tray).
10. Performance profiling and accessibility pass, on devices.

Screens are wired to real engine view models as each platform phase lands; until then they run on fake providers so design work doesn't wait on networking.

---

## 12. Open design questions

1. **Accent colour.** The web app uses signal lime (`--accent`) for "live link" and red only for "verified"; the site and this brief use red. Plan: the app goes red-only, the web app is left as is until the browser guest UI is next touched. Confirm.
2. **Light theme.** Brief specifies a dark environment. Plan: dark only at first, tokens structured so a light theme can be added. Confirm.
3. **Font.** Plan uses each platform's system font with tabular numbers, per the brief, rather than Geist (web app) or Archivo (site). Confirm.

---

## 13. Phase 3 design decisions

Reference: Apple's Liquid Glass overview (developer.apple.com/documentation/technologyoverviews/liquid-glass). The principles taken from it, not the look: glass is reserved for the **navigation and control layer** that floats above content; content itself stays solid and legible; the material takes colour and light from what's behind it; controls morph and respond instead of simply appearing; one clear hierarchy of layers.

| Topic | Decision |
|---|---|
| Material names | The four levels become `GlassLevel.regular / elevated / floating / sheet` (was surface / card / floating / sheet). Regular and elevated never blur; floating and sheet blur for real. Budget of two real blurs stays, with the debug guard. |
| Material response | Each level gets an *interaction response*: elevated surfaces brighten their rim and lift (shadow + 1 pt translate) on hover/press; floating glass picks up a tint from the environment state (red when a transfer is live). A **specular sheen** follows the pointer on desktop (a gradient in the edge painter, no extra layer). |
| Environment states | `AmbientBackground` becomes state-driven: `idle` (calm), `searching` (slow breathing of the cool field), `connected` (soft glow where the devices are), `transferring` (a faint directional band along the transfer axis, speed tied to measured throughput, capped), `completed` (one short red bloom, then back to idle). Reduce Motion: static per state. |
| Home | Title block ("SwiftDrop", "Send anything. Directly."), a spatial **nearby field** (devices as objects, not a list), and one dominant floating **Send** action (red, largest element). Receive stays one tap away (dock on phone, header on desktop). |
| Transfer screen | Spatial view: sender and receiver glyphs on one axis, a connection line whose **file tokens** advance with *measured* bytes (position = bytes done / total; density = files in flight), central tabular readout (bytes, %, speed, remaining). No animation runs faster than the data. |
| Device states | Searching · Available · Connecting · Connected · Busy · Offline, each with words + icon; connected devices carry the only red rim. |
| Desktop | Workstation layout: sidebar · content canvas · right **transfer panel** (live transfer or selected device) at ≥ 1240 pt; drop files anywhere, or onto a device card to send to it; context menus on devices and history rows. |
| Screens checked | 390×844, 430×932, 768×1024, 1200×800, 1440×900 via a screenshot tool (`tool/screens.dart`) rendering real fonts. |
| Not faked | Pairing confirmation codes, "verified device" badges and scan success are shown in the design gallery only until Phase 7 wires real pairing. |

---

## 14. Phase 3 as built

- Levels `regular / elevated / floating / sheet`; fills are a faint top-lit gradient; elevated and interactive surfaces lift 2 pt and brighten their rim on hover, with a pointer sheen on desktop. Real blur only on the floating panel (tabs + action dock on phones), the sidebar, the send dock and sheets; the debug guard (≤ 2) holds on every screen at all five sizes (widget test).
- Environment: idle / searching (pairing screen) / connected / transferring (band paced by measured throughput) / one bloom per completed transfer; all derived from engine state in `environmentProvider`; static under Reduce Motion.
- Transfer visual: the link fills with confirmed bytes and file tokens advance only with confirmed bytes; snapshots are eased by `SmoothValue`, which never runs ahead of the latest real value.
- Menus stay solid (they'd otherwise be a third blur). The QR sits on an opaque tile inside elevated glass.
- New type roles `micro` and `numericMedium`; new motion token `breath`. Screens and app code contain no raw colours, durations, font sizes, radii or icon-package imports (test-enforced).
- Screenshot tool: `flutter test test_screens --dart-define=SCREENS_OUT=<folder> [--dart-define=SIZES=all]`.
- Confirmation codes (`SasCode`) exist in the gallery only until Phase 7 pairing.
