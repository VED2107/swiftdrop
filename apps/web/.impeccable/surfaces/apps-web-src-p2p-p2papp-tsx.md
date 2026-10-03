---
version: 1
slug: "apps-web-src-p2p-p2papp-tsx"
primary_target: "apps/web/src/p2p/P2PApp.tsx"
related_targets: ["apps/web/p2p.html"]
---

# /p2p/ phone to phone (web)

Scope: apps/web p2p.html, the browser app for phone to phone and phone to desktop browser. Mode: Operate.
Audience: anyone with two phones (often iPhone, no app possible), same Wi-Fi or hotspot. Job: move photos, videos, files directly, fast. Constraints: every number live; never claim "local" without getStats proof; file bytes never touch a server.
Flow (user-confirmed 2026-10-04): sender taps Send, picks files, one QR appears; receiver taps Receive and scans (or opens the QR with the Camera app); receiver accepts; transfer. Nobody scans back.
Visual authority: user-pinned concept board `SwiftDrop File Transfer Concept Board.png` (repo root). No concept roll: pinned direction beats the roll.

## Direction contract

THESIS: the browser page is the SwiftDrop app, not a QR utility or a landing page; refuses the "steps 1-2-3 explainer + generic QR box" arrangement.
OWN-WORLD: near-black graphite ground with a warm red bloom behind the hero device pair; frosted glass cards (blur, 1px white/10 edge, inset highlight), SwiftDrop red (#EF2B3C family) as the only accent, Geist + Geist Mono numerals, 20px card radius, pill buttons, large white QR plate with the red mark in the centre.
STORY: open, see two big choices; Send shows a QR within a second while the picker returns; Receive is a scanner; connected state names the other phone and the proven path; the transfer card is the hero: file name, bar, bytes, live speed, files left, Cancel; complete shows verified.
FIRST VIEWPORT: wordmark + status pill top; device-pair hero art with red bloom; headline "Send anything. Directly."; two stacked full-width glass buttons (Send red, Receive glass) within thumb reach; recent transfers below. Desktop: same app centred in a 1100px two-pane shell, right pane recent + this device.
FORM: concept board as pinned world (position 1 of 1, user-pinned); seed key: none (pinned, roll skipped).
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
