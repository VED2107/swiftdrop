---
name: SwiftDrop /p2p/
description: The SwiftDrop app in a browser. Graphite ground, frosted glass, one red.
colors:
  graphite-ground: "#0e0e10"
  graphite-sink: "#0a0a0c"
  graphite-surface: "#17171a"
  graphite-surface-2: "#1c1c20"
  graphite-surface-3: "#26262b"
  hairline: "rgb(255 255 255 / 0.08)"
  hairline-strong: "rgb(255 255 255 / 0.14)"
  text: "rgb(255 255 255 / 0.94)"
  text-2: "rgb(255 255 255 / 0.66)"
  text-3: "rgb(255 255 255 / 0.5)"
  text-4: "rgb(255 255 255 / 0.36)"
  swiftdrop-red: "#d8322a"
  red-lit: "#ef4236"
  red-deep: "#a91f18"
  red-on-dark: "#ff8a80"
  red-wash: "rgb(216 50 42 / 0.14)"
  on-red: "#ffffff"
  verified-green: "#6fdc9c"
  warning-apricot: "#ffb38a"
  warning-wash: "rgb(255 179 138 / 0.12)"
  ambient-cool: "#3a4150"
  qr-paper: "#fafafa"
typography:
  display:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, -apple-system, Segoe UI, sans-serif"
    fontSize: "clamp(2.6rem, 1.9rem + 3vw, 4rem)"
    fontWeight: 650
    lineHeight: 1.02
    letterSpacing: "-0.04em"
  speed-numeral:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(2.6rem, 2rem + 3vw, 3.6rem)"
    fontWeight: 560
    lineHeight: 1
    letterSpacing: "-0.05em"
    fontFeature: "\"tnum\", \"ss01\""
  headline:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(1.7rem, 1.4rem + 1.2vw, 2.1rem)"
    fontWeight: 620
    lineHeight: 1.12
    letterSpacing: "-0.032em"
  title:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.15rem"
    fontWeight: 620
    letterSpacing: "-0.02em"
  section:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 600
    letterSpacing: "-0.015em"
  body:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.02rem"
    fontWeight: 400
    lineHeight: 1.5
    fontFeature: "\"ss01\", \"cv11\""
  row-title:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.95rem"
    fontWeight: 560
    letterSpacing: "-0.012em"
  label:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.82rem"
    fontWeight: 520
  mono:
    fontFamily: "Geist Mono Variable, ui-monospace, SF Mono, Consolas, monospace"
    fontSize: "0.9rem"
rounded:
  glyph: "11px"
  row: "16px"
  card: "20px"
  tile: "24px"
  window: "28px"
  full: "999px"
spacing:
  s-1: "4px"
  s-2: "8px"
  s-3: "12px"
  s-4: "16px"
  s-5: "20px"
  s-6: "24px"
  s-8: "32px"
  s-10: "40px"
  s-12: "48px"
components:
  button-primary:
    backgroundColor: "{colors.swiftdrop-red}"
    textColor: "{colors.on-red}"
    rounded: "{rounded.full}"
    padding: "0 20px"
    height: "44px"
  button-primary-large:
    backgroundColor: "{colors.swiftdrop-red}"
    textColor: "{colors.on-red}"
    rounded: "{rounded.full}"
    padding: "0 24px"
    height: "56px"
  button-primary-disabled:
    backgroundColor: "{colors.graphite-surface-2}"
    textColor: "{colors.text-4}"
  button-glass:
    textColor: "{colors.text}"
    rounded: "{rounded.full}"
    padding: "0 20px"
    height: "44px"
  field:
    textColor: "{colors.text}"
    rounded: "{rounded.full}"
    padding: "0 16px"
    height: "48px"
  card-glass:
    rounded: "{rounded.card}"
    padding: "22px 20px 18px"
  choice-tile-send:
    backgroundColor: "{colors.swiftdrop-red}"
    textColor: "{colors.on-red}"
    rounded: "{rounded.tile}"
    padding: "18px"
    height: "156px"
  choice-tile-receive:
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "18px"
    height: "156px"
  status-pill:
    textColor: "{colors.text-2}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    padding: "0 14px"
    height: "32px"
  verified-chip:
    backgroundColor: "rgb(111 220 156 / 0.12)"
    textColor: "{colors.verified-green}"
    rounded: "{rounded.full}"
    padding: "0 12px"
    height: "28px"
  qr-plate:
    backgroundColor: "{colors.qr-paper}"
    rounded: "{rounded.window}"
    padding: "18px"
    width: "min(78vw, 320px)"
  alert:
    backgroundColor: "{colors.warning-wash}"
    textColor: "{colors.text}"
    rounded: "{rounded.row}"
    padding: "12px 12px 12px 16px"
---

# Design System: SwiftDrop /p2p/

<!-- SCOPE: this file documents the /p2p/ surface only (apps/web/p2p.html, src/p2p/P2PApp.tsx + src/p2p/p2p.css). The PC app at apps/web/index.html keeps its own lime "Quiet Signal" world in src/styles.css and is NOT described here. p2p.css loads after styles.css, unlayered, and overrides its :root tokens for p2p.html only; spacing, radii scale, motion and font stacks are inherited from styles.css unchanged. Red is shared with the native app: apps/swiftdrop/lib/design/tokens/colors.dart. -->

## Overview

**Creative North Star: "The App in the Browser"**

The /p2p/ page is the SwiftDrop app running in a browser tab, the same world as the native Flutter app: near-black graphite ground, frosted glass surfaces, and one red. Nothing on screen reads as a web page or a QR utility; it is one app window with a top bar, a single primary pane, and (on desktop) a side pane. Density is phone-first: one column at 480px max, thumb-reach tiles, big honest numbers.

Red carries two meanings only: "act here" and "data is moving". It fills the Send tile, primary buttons, the progress bar, the completion mark and the brand mark; it blooms softly behind the hero device pair. Green is a status colour, not an accent: it appears on the live connection dot and the Verified chip. Everything else is white at stepped opacity on graphite.

Glass is a web approximation of the native material: a faint white vertical gradient, a 1px inset edge plus a top highlight, backdrop blur with saturation, and a long soft drop. Under `prefers-reduced-transparency` every glass surface falls back to a solid graphite fill.

**Key Characteristics:**
- Graphite ground with a red radial bloom at the top and a cool ambient field at the bottom right.
- Frosted glass for every container; no visible borders, only inset edges.
- One red accent, gradient-lit (lighter top, deeper bottom) on fills.
- Pill geometry for every control; 20-28px radii for containers.
- Geist with tabular numerals for every live number.
- The QR is a flat near-white plate, never on glass, never marked.

## Colors

A graphite monochrome lit by a single warm red, with green and apricot reserved for state.

### Primary
- **SwiftDrop Red** (`swiftdrop-red`): the shared native token. Primary button base, Send tile, brand mark, progress bar, dashed drop-zone edge, live viewfinder corners, `::selection`.
- **Lit Red** (`red-lit`): the top stop of every red gradient (buttons, tiles, marks) and the bright end of the progress bar.
- **Deep Red** (`red-deep`): the bottom stop of the Send tile and completion mark. Native `redPressed` is #A8221A; the web uses #a91f18 and #b9241d as hardcoded stops (see drift).
- **Red on Dark** (`red-on-dark`): red for small text, links and the focus outline on graphite, where the base red fails contrast.
- **Red Wash** (`red-wash`): tinted halos, the 10px ring around the completion mark, and the background bloom (at 0.2-0.32 alpha).

### Neutral
- **Graphite Ground** (`graphite-ground`): page background; matches native `ground`.
- **Graphite Sink** (`graphite-sink`): deepest field.
- **Graphite Surfaces 1-3** (`graphite-surface`, `-2`, `-3`): solid fills for disabled primary buttons and the reduced-transparency fallback (`-2`); scrollbar thumb (`-3`).
- **Hairlines** (`hairline`, `hairline-strong`): the desktop side-pane divider, the device-line rule, the progress track ends.
- **Text 1-4** (`text` to `text-4`): white at 0.94 / 0.66 / 0.5 / 0.36. Primary copy, secondary copy, metadata, and the dimmed second line of the display headline.
- **QR Paper** (`qr-paper`): the only near-pure white field, because scanners need maximum contrast.
- **Ambient Cool** (`ambient-cool`): the bottom-right background field at 0.35 alpha.

### State
- **Verified Green** (`verified-green`): live connection dot (with a 3px 0.16 halo) and the Verified chip. Nowhere else.
- **Warning Apricot** (`warning-apricot`, `warning-wash`): warn dot and the alert strip, always with a word, never colour alone.

### Named Rules
**The One Red Rule.** Red means "act" or "data moving". It is never decoration, never a second accent hue, and the web red is the native token: change it in colors.dart and here together.

**The Status Is Not Accent Rule.** Green and apricot are states. They never fill a button, a tile, or a headline.

**The Plain Plate Rule.** The QR sits on flat `qr-paper` with no centre mark, tint, blur or glass: a full SDP offer needs every module readable at arm's length.

## Typography

**Display Font:** Geist Variable (with ui-sans-serif, system-ui, -apple-system, Segoe UI)
**Label/Mono Font:** Geist Mono Variable (with ui-monospace, SF Mono, Consolas)

**Character:** one tight, confident grotesque at fractional weights (520-650) with negative tracking that grows as size grows. Mono appears only for pasted codes and the debug panel.

### Hierarchy
- **Display** (650, fluid 2.6-4rem, 1.02): home headline only. Two lines, the second dimmed to `text-4` ("Send anything. / Directly.").
- **Speed Numeral** (560, fluid 2.6-3.6rem, 1, -0.05em, tabular): the live MB/s in the transfer card; its unit is a `text-3` small at 0.36em.
- **Headline** (620, fluid 1.7-2.1rem, 1.12): screen titles and the file name on the transfer screen.
- **Title** (620, 1.15rem): choice tile titles.
- **Section** (600, 1rem): pane headings such as "Recent transfers".
- **Body / Lead** (400, 1.02rem, 1.5, max 44ch, `text-2`): explanatory lines under headlines. Notes drop to 0.84rem in `text-3`.
- **Row Title / Row Sub** (560 at 0.95rem / 400 at 0.8rem `text-3`): list rows.
- **Label** (520, 0.82rem): pills and chips.

### Named Rules
**The Tabular Numbers Rule.** Every live number (speed, percent, bytes, time left, file counts) uses tabular figures (`"tnum", "ss01"`), so values update without jitter.

**The Tracking Scales With Size Rule.** Tracking tightens with size: -0.012em on rows, -0.02em on titles, -0.032em on headlines, -0.04 to -0.05em on display and speed.

## Layout

Phone: one column, max 480px, 16px side padding, safe-area aware top and bottom. A 64px sticky top bar holds the wordmark and the status pill on a fading graphite gradient with a 12px blur. Main content stacks on a 16px gap; screen groups use 24px; the hero bleeds 16px past the column.

Desktop (from 960px): the shell becomes one glass app window, max 1160px, min height `min(720px, 100dvh - 120px)`, 28px radius, two columns: a main pane (content max 600px, centred, 40/32/48px padding) and a fixed 360px side pane on a darker `rgb(0 0 0 / 0.18)` fill divided by an inset hairline. The side pane holds "this device" and recent transfers; on phones recent transfers live on the home screen only, and the device line moves to the top bar.

Spacing follows the inherited 4px scale (4, 8, 12, 16, 20, 24, 32, 40, 48). Action rows split into equal columns with an 8px gap; the home choice tiles are a two-column grid with a 12px gap.

## Elevation & Depth

Depth comes from translucency and light, not from stacked solid cards. Glass surfaces carry an inset edge and a long, soft, low-opacity drop; red elements carry a red-tinted glow beneath them. There are no hard or offset shadows.

### Shadow Vocabulary
- **Glass edge** (`box-shadow: inset 0 1px 0 rgb(255 255 255 / 0.1), inset 0 0 0 1px rgb(255 255 255 / 0.075)`): the border of every glass surface, pill, field and button.
- **Glass drop** (`box-shadow: 0 24px 60px -28px rgb(0 0 0 / 0.85)`): lift under cards, tiles and the viewfinder.
- **Window drop** (`box-shadow: 0 40px 120px -40px rgb(0 0 0 / 0.9)`): the desktop app window only.
- **Red glow** (`box-shadow: inset 0 1px 0 rgb(255 255 255 / 0.22), 0 12px 28px -12px rgb(216 50 42 / 0.75)`): primary buttons; the Send tile uses a larger version (`0 24px 50px -22px`, 0.9).
- **Bar glow** (`box-shadow: 0 0 18px rgb(239 66 54 / 0.45)`): the progress fill while moving; removed when paused.

### Named Rules
**The Glass Not Border Rule.** Containers are defined by an inset white edge and blur, never by a solid stroke. The only real borders are the scanner corner brackets and the dashed drop zone.

**The Lit From Above Rule.** Every fill gets a 1px inset top highlight and a top-to-bottom gradient, lighter at the top.

## Shapes

Round and soft throughout. Controls are full pills (999px): buttons, fields, the status pill, chips, text links, the progress track. Containers step up with size: icon glyph squares 11px, list rows 14-16px, glass cards 20px, choice tiles and device glyphs 18-24px, QR plate, viewfinder, drop zone and desktop window 28px. The brand mark, choice-tile icons and the completion mark are circles. The scanner viewfinder carries four 34px corner brackets (3px white strokes with a 12px rounded outer corner) that turn red when the camera is live.

## Components

### Buttons
Tactile pills, lit from above.
- **Shape:** full pill (999px), 44px tall by default, 56px for large actions.
- **Primary:** vertical gradient from `red-lit` to `swiftdrop-red`, white label at 520 weight, red glow beneath.
- **Hover (fine pointer):** brighter gradient (#f34c40 to #df372e) and a deeper glow. **Active:** scale 0.97 over 140ms.
- **Disabled primary:** solid `graphite-surface-2` with `text-4`, no glow.
- **Glass:** glass fill and edge, `text` label, 20px blur; hover lifts the fill to 0.11/0.06 white. Used for Cancel and secondary actions.
- **Text link:** transparent pill, `text-3` at 0.85rem; hover brightens to `text` on a 0.05 white wash.

### Chips
- **Status pill:** 32px glass pill with a 7px state dot (grey idle, green live, apricot warn) and `text-2` label; names the proven path ("Direct · Local network").
- **Verified chip:** 28px green-washed pill with a check and `verified-green` label, shown on completion.

### Cards / Containers
- **Corner Style:** 20px for glass cards.
- **Background:** glass fill (white 0.075 to 0.04 vertical gradient) with blur 24px, saturate 150%.
- **Shadow Strategy:** glass edge plus glass drop (see Elevation).
- **Border:** none; inset edge only.
- **Internal Padding:** 20px (meter 22/20/18px); list containers 6px with 8/10px rows.

### Inputs / Fields
- **Style:** 48px glass pill, 16px padding, 0.9rem `text`, placeholder `text-3` in Geist; pasted content switches to Geist Mono.
- **Focus:** the global 2px outline at 3px offset in `red-on-dark`.

### Navigation
- **Top bar:** brand (28px red radial mark with a send glyph, 1.06rem 640 wordmark) on the left, status pill on the right. No menus or tabs.

### Choice Tiles (signature)
Two side-by-side 156px tiles with a 24px radius, an icon circle (46px) at the top and the title plus a two-line subtitle anchored at the bottom so both titles share a baseline. Send is solid red (160deg gradient #e5392f to #a91f18 with a white radial sheen); Receive is glass. Press scales to 0.97.

### Transfer Meter (signature)
The hero of the transfer screen: a glass card with the speed numeral and percent on one baseline, an 8px pill track (white 0.08) filling with a deep-to-lit red gradient and glow (220ms linear transform), and a `text-3` foot row of bytes, time left, files remaining and average speed. Paused turns the fill to white 0.32 with no glow.

### QR Plate (signature)
A `qr-paper` square, `min(78vw, 320px)`, 18px padding, 28px radius, with a red-tinted under-glow. Enters with a 420ms scale-and-unblur; while pending it shows a glass shimmer at the same size.

### Completion Mark
An 84px red radial circle with a white check, a 10px red-wash ring and red glow, entering over 520ms with a scale-and-unblur. Paired with the Verified chip.

### Motion
Inherited easing `--ease-out` (cubic-bezier(0.23, 1, 0.32, 1)) with 140ms micro and 240ms UI durations. Entrances use scale plus blur, never slides. Every animation and the bar transition stop under `prefers-reduced-motion`.

## Do's and Don'ts

### Do:
- **Do** take the red from the native token (#D8322A) and keep web and app on one red.
- **Do** build every container from the glass recipe (fill, inset edge, blur, soft drop) and give it a solid `graphite-surface-2` fallback under `prefers-reduced-transparency`.
- **Do** use full pills for every control and 20-28px radii for containers.
- **Do** set every live number in tabular figures.
- **Do** keep the QR on a flat `qr-paper` plate with no centre mark.
- **Do** pair every warning colour with a word and an icon.

### Don't:
- **Don't** add a second accent hue; green and apricot are status only.
- **Don't** use red for decoration that does not mean "act" or "data moving".
- **Don't** draw solid borders on containers; use the inset glass edge.
- **Don't** put the QR on glass, tint it, or blur it.
- **Don't** pull lime or other values from the PC app's "Quiet Signal" world into /p2p/.
