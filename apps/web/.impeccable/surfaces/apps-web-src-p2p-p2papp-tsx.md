---
version: 1
slug: "apps-web-src-p2p-p2papp-tsx"
primary_target: "apps/web/src/p2p/P2PApp.tsx"
related_targets: ["apps/web/p2p.html"]
---

# /p2p/ phone to phone (web)

Scope: apps/web p2p.html, the browser app for phone to phone and phone to desktop browser. Mode: Operate.
Audience: anyone with two phones (often iPhone, no app possible), same Wi-Fi or hotspot. Job: move photos, videos, files directly, fast. Constraints: every number live; never claim "local" without getStats proof; file bytes never touch a server.
Flow (user-confirmed 2026-10-04): sender taps Send, picks files, one QR appears; receiver taps Receive and scans (or opens the QR with the Camera app); receiver accepts; transfer. Nobody scans back. Once connected, either phone can send (user, 2026-10-04): the connection is a session, not a one-way pipe.
Visual authority: user-pinned concept board `SwiftDrop File Transfer Concept Board.png` (repo root). No concept roll: pinned direction beats the roll.

## Direction contract

THESIS: the browser page is the SwiftDrop app, not a QR utility or a landing page; refuses the "steps 1-2-3 explainer + generic QR box" arrangement.
OWN-WORLD: near-black graphite ground with a warm red bloom behind the hero device pair; frosted glass cards (blur, 1px white/10 edge, inset highlight), SwiftDrop red #D8322A (the native Flutter token, apps/swiftdrop/lib/design/tokens/colors.dart; shared so web and app are one red) as the only accent, Geist + Geist Mono numerals, 20px card radius, pill buttons, large white QR plate (no centre mark: see cited decisions).
STORY: open, see two big choices; Send shows a QR within a second while the picker returns; Receive is a scanner; connected state names the other phone and the proven path; the transfer card is the hero: file name, bar, bytes, live speed, files left, Cancel; complete shows verified.
FIRST VIEWPORT: wordmark + status pill top; device-pair hero art with red bloom; headline "Send anything. Directly."; two large side-by-side tiles (Send red, Receive glass) within thumb reach, as on the board's Android/iOS home; recent transfers below. Desktop: one glass app window (~1160px), main pane + side pane (this device, recent transfers).
FORM: concept board as pinned world (position 1 of 1, user-pinned); seed key: none (pinned, roll skipped).
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Cited decisions (finish review 1)

- Accent stays #D8322A: the contract's earlier "#EF2B3C" was a slip; the shared native token wins (one red across platforms).
- Home tiles side by side: the board's phone homes show tiles; the contract text is corrected.
- No mark in the QR centre: the code carries a full SDP offer (~700-900 chars). ECC Q/H with a knockout pushes the symbol to a denser version that phone cameras read less reliably at arm's length; scanability wins. The red mark sits in the top bar instead.
- Device-pair hero art: still the live Connection component (state-carrying, animated). A rendered device-pair raster needs image generation the user has not approved spending on; open item.
- Reply-QR link appears only when the rendezvous is unreachable (or pairing is set offline).
