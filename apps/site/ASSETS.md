# Site asset provenance

- `public/frames/f01-f14.webp`: sample photos standing in for a camera roll. Unsplash photos (Unsplash License) fetched via picsum.photos ids 1015, 1025, 1035, 1043, 1050, 1060, 1069, 1080, 1084, 1011, 1039, 1059, 1062, 1074 at 640x480, converted to WebP with ffmpeg. Replace with your own photos any time.
- `public/shots/*.webp`: real screenshots of the SwiftDrop app, captured by `scripts/site-shots.mjs` (test-mode server, simulated iPhone). The save path is replaced with a generic one and loopback timings are hidden, since they are not Wi-Fi speeds.
- `public/shots/p2p-*.webp`: real screenshots of phone to phone, captured by `scripts/site-shots-p2p.mjs` (two simulated iPhones over a real WebRTC link on loopback). Speeds, time left and durations are hidden, since loopback is not Wi-Fi. The pairing code shown is drawn in a default browser profile, so it carries no machine addresses.
- Icons: `assets/brand` (rendered by `scripts/build-icons.mjs`); download glyph from Phosphor Icons (MIT).
