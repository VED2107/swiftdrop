# SwiftDrop "Instrument" design system

A precision instrument for moving things. The connection is the interface: two devices are
endpoints, a transfer rail joins them, files are objects that travel along it.

Replaces the glass world (2026-10-04). Applies to the Flutter app (Windows, macOS, Linux,
Android), the browser client an iPhone opens from the app's QR, and the public site.

## Vocabulary

DEVICE → PATH → FILES → DESTINATION

| Part | What it is | Never |
|---|---|---|
| **Endpoint** | A device as a destination: oversized name, a printed legend (kind, address), one status lamp. Flat, no container. | a card |
| **Rail** | The path between two endpoints. Idle: a dormant engraved line. Linked: lit. Moving: file objects travel along it; thickness = link quality, tick spacing = speed, the fill behind the objects = progress. Done: resolves to a single verified line with a check. | a progress bar |
| **Object** | A file as a physical chip: thumbnail or type glyph, a short name, size. Snaps (magnetic spring) into the tray and onto the rail. | a list row |
| **Tray** | Where picked files wait at the origin, grouped by kind. Drop target on desktop. | a modal |
| **Key** | Controls. One round red **Send key**; everything else is a flat rectangular key with a printed legend and 2 px of travel. | a floating pill |
| **Readout** | Numbers set in mono, tabular, oversized where they matter (MB/s, %). Attached to the rail, not floating in a card. | a stat tile |
| **Drawer** | Panels slide in from the edge they belong to (QR / receive from the right, history from below). | stacked cards |

## Material

- **Ground** warm graphite `#131114`. **Panel** `#1A171B`, flat, no blur, no gradient.
- **Engraving**: separators are a 1 px dark line with a 1 px light line under it (a machined
  groove). Used instead of boxes.
- **Ink** `#F4EFEA`, **ink-2** `#A79E99`, **ink-3** `#6F6763`. Legends: 11-12 px, caps,
  +0.08em tracking, like the printing on a Braun panel.
- **Signal red** `#D8322A` (lit `#EF4236`) is reserved for three things: the Send key, the
  live rail, moving objects. **Verified green** `#6FDC9C` only when the rail resolves.
- Radius: 6 px "machined" corners on keys and objects; circles only for endpoints' lamps and
  the Send key. No pills, no glass, no neon, no gradients except the Send key's single
  top-light.

## Type

Geist for words, Geist Mono for numbers. Device names display at 40-56 px, weight 600,
-0.03em. Speed readout 64-96 px mono. Body 15-16 px. Legends small caps.

## Motion

- Objects move at a speed proportional to the live MB/s; never faster than the data.
- Magnetic snap: spring, 260 ms, ~4% overshoot, when an object lands in the tray or rail.
- Keys: 2 px travel, 90 ms down, 160 ms up.
- Resolve: the rail settles from red to one green line in 420 ms, objects stack at the
  destination with a check.
- Reduce Motion: no travel; the rail fills and resolves with opacity only.

## Layout

Wide (desktop, tablet landscape): the rail runs horizontally, this device on the left,
the destination on the right. Narrow (phones): the rail runs vertically, destination at
the top, this device and the Send key at the bottom in thumb reach. Same parts, rotated.
