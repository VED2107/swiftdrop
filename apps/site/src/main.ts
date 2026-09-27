import "../../web/src/styles.css";
import "./site.css";

const DOWNLOAD_URL: string =
  import.meta.env.VITE_DOWNLOAD_URL || "https://github.com/VED2107/swiftdrop/releases/latest/download/SwiftDrop.exe";

for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-download]")) a.href = DOWNLOAD_URL;

// On a phone the download isn't for this device: say so instead of offering a .exe.
if (/iPhone|iPad|Android/.test(navigator.userAgent)) {
  for (const n of document.querySelectorAll("[data-platform-note]")) n.textContent = "Download it on your Windows PC, then scan the code with this phone.";
}

// Particle stream for the hero link; same markup and CSS as the app's transfer state.
const stream = document.querySelector("[data-stream]");
if (stream) {
  const dy = [0, -3, 2, -1, 3, -2, 1, -3, 2, 0, -2, 3];
  for (let k = 0; k < 12; k++) {
    const p = document.createElement("span");
    p.className = "particle";
    p.style.setProperty("--k", String(k));
    p.style.setProperty("--dy", `${dy[k]}px`);
    stream.append(p);
  }
  const link = stream.closest<HTMLElement>(".link");
  const track = stream.parentElement;
  if (link && track) {
    const set = () => link.style.setProperty("--track-w", `${track.clientWidth + 20}px`);
    new ResizeObserver(set).observe(track);
    set();
  }
}
