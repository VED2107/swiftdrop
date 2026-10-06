import "./site.css";
import downloadIcon from "@phosphor-icons/core/assets/bold/download-simple-bold.svg?raw";
import phonesIcon from "@phosphor-icons/core/assets/bold/device-mobile-bold.svg?raw";
import arrowIcon from "@phosphor-icons/core/assets/bold/arrow-up-bold.svg?raw";
import arrowDownIcon from "@phosphor-icons/core/assets/bold/arrow-down-bold.svg?raw";
import checkIcon from "@phosphor-icons/core/assets/bold/check-bold.svg?raw";
import desktopIcon from "@phosphor-icons/core/assets/bold/desktop-bold.svg?raw";
import qrIcon from "@phosphor-icons/core/assets/bold/qr-code-bold.svg?raw";

document.documentElement.classList.add("js");

const DOWNLOAD_URL: string = import.meta.env.VITE_DOWNLOAD_URL || "https://github.com/VED2107/swiftdrop/releases/download/v1.1.0/SwiftDrop-Setup-1.1.0.exe";
// The Android APK ships on the same releases page until it is in a store.
const ANDROID_URL: string = import.meta.env.VITE_ANDROID_URL || "https://github.com/VED2107/swiftdrop/releases/download/v1.1.0/SwiftDrop-1.1.0.apk";
const reduced = matchMedia("(prefers-reduced-motion: reduce)");

for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-download]")) a.href = DOWNLOAD_URL;
// The version shown on the page is the one the download links point at.
const VERSION = /v(\d+\.\d+\.\d+)\//.exec(DOWNLOAD_URL)?.[1] ?? "";
if (VERSION) for (const n of document.querySelectorAll("[data-version]")) n.textContent = VERSION;
for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-android]")) a.href = ANDROID_URL;
// On a phone the installer isn't for this device: say where it goes instead.
if (/iPhone|iPad|Android/.test(navigator.userAgent)) {
  for (const n of document.querySelectorAll("[data-platform-note]")) n.textContent = /Android/.test(navigator.userAgent) ? "Get SwiftDrop for Android, or scan the code SwiftDrop shows on your PC." : "On iPhone there is nothing to install: point the camera at the code SwiftDrop shows on your PC or Android.";
}

const SWIFT = `<svg viewBox="0 0 256 256"><defs><radialGradient id="sdg" cx="0.32" cy="0.26" r="0.95"><stop offset="0" stop-color="#ef4236"/><stop offset="1" stop-color="#a91f18"/></radialGradient></defs><rect width="256" height="256" rx="64" fill="url(#sdg)"/><path transform="translate(128 128) scale(0.62) translate(-128 -124)" fill="#fff" d="M79.45 204.94 L98.16 150.71 L41.5 159.72 L97.57 75.35 A62.32 62.32 0 1 1 172.27 164.37 Z"/></svg>`;
const ICONS: Record<string, string> = { logo: SWIFT, download: downloadIcon, phones: phonesIcon, arrow: arrowIcon, arrowDown: arrowDownIcon, check: checkIcon, desktop: desktopIcon, qr: qrIcon };
for (const el of document.querySelectorAll<HTMLElement>("[data-icon]")) el.innerHTML = ICONS[el.dataset.icon!] ?? "";

// Sections arrive once, as they scroll in; siblings stagger by 70 ms.
const reveal = new IntersectionObserver(
  (entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      e.target.classList.add("is-in");
      reveal.unobserve(e.target);
    }
  },
  { threshold: 0.2, rootMargin: "0px 0px -8% 0px" },
);
for (const group of document.querySelectorAll<HTMLElement>(".tiles, .steps, .calm-grid")) {
  [...group.querySelectorAll<HTMLElement>("[data-reveal]")].forEach((el, i) => el.style.setProperty("--i", String(i)));
}
for (const el of document.querySelectorAll("[data-reveal]")) reveal.observe(el);

// ---------------------------------------------------------------------------
// The signature: a photo leaves the phone, arcs over to the PC and lands with a green
// check. It plays a few times on its own when the hero is first seen, then waits for a
// tap. Photo colours are drawn, not fetched: each chip is a small gradient "photo".

const stage = document.querySelector<HTMLElement>("[data-stage]");
const flight = document.querySelector<HTMLElement>("[data-flight]");
const toss = document.querySelector<HTMLButtonElement>("[data-toss]");
const SKIES = [
  ["#f6a26b", "#c4485a", "#3b2a55"],
  ["#8fd3f4", "#4a7fb8", "#1f2b4a"],
  ["#ffd27a", "#e9764f", "#5a2c3a"],
  ["#b6e3a8", "#4e9a7a", "#1d3a3a"],
  ["#f7c6d9", "#b56a9c", "#3a2346"],
];
let n = 0;
let inFlight = 0;
const progress = document.querySelector<HTMLElement>("[data-progress]");
const toasts = document.querySelector<HTMLElement>("[data-toasts]");
const tossLabel = document.querySelector<HTMLElement>("[data-toss-label]");

function photo(sky: string[]) {
  return `radial-gradient(circle at 70% 30%, ${sky[0]} 0 14%, transparent 15%), linear-gradient(170deg, ${sky[0]}, ${sky[1]} 55%, ${sky[2]})`;
}

/** One photo: leaves the phone (it glows), arcs with a comet tail, lands on the PC window
    (progress fills, a "Received" toast springs in, the window rims green for a beat). */
function send() {
  if (!flight || !stage || reduced.matches) return;
  const idx = n++;
  const sky = SKIES[idx % SKIES.length]!;
  const w = flight.clientWidth;
  const h = flight.clientHeight;
  // From the phone's thumbnail row to the PC's receiving card, one smooth arc.
  const path = `path("M 0 0 C ${w * 0.12} ${-h * 0.5}, ${w * 0.36} ${-h * 0.66}, ${w * 0.5} ${-h * 0.42}")`;

  inFlight++;
  stage.classList.add("is-sending");
  stage.classList.remove("is-landed");
  if (progress) {
    progress.style.transition = "none";
    progress.style.transform = "scaleX(0)";
    void progress.offsetWidth;
    progress.style.transition = "transform 1.15s cubic-bezier(0.4, 0, 0.2, 1)";
    progress.style.transform = "scaleX(1)";
  }

  for (const [i, delay] of [70, 140, 210].entries()) {
    const t = document.createElement("span");
    t.className = "trail";
    t.style.offsetPath = path;
    t.style.animationDelay = `${delay}ms`;
    t.style.scale = String(1 - i * 0.22);
    flight.append(t);
    setTimeout(() => t.remove(), 1600);
  }
  const chip = document.createElement("span");
  chip.className = "chip";
  chip.style.backgroundImage = photo(sky);
  chip.style.offsetPath = path;
  flight.append(chip);

  setTimeout(() => {
    inFlight--;
    stage.classList.add("is-landed");
    surge();
    if (inFlight === 0) stage.classList.remove("is-sending");
    setTimeout(() => inFlight === 0 && stage.classList.remove("is-landed"), 700);
    if (toasts) {
      const toast = document.createElement("span");
      toast.className = "toast";
      toast.innerHTML = `<i style="background-image:${photo(sky)}"></i>IMG_${4831 + idx}.HEIC <b>Received</b>`;
      toasts.prepend(toast);
      while (toasts.children.length > 3) toasts.lastElementChild!.remove();
      setTimeout(() => toast.classList.add("is-out"), 2400);
      setTimeout(() => toast.remove(), 2800);
    }
  }, 1150);
  setTimeout(() => chip.classList.add("is-gone"), 2100);
  setTimeout(() => chip.remove(), 2600);
}

let taps = 0;
toss?.addEventListener("click", () => {
  taps++;
  toss.classList.add("was-used");
  toss.classList.remove("is-launch");
  void toss.offsetWidth;
  toss.classList.add("is-launch");
  send();
  if (tossLabel) tossLabel.textContent = taps === 1 ? "Send another" : `${taps} sent. Again?`;
});
if (stage) {
  let played = false;
  new IntersectionObserver(
    (entries, io) => {
      if (played || !entries.some((e) => e.isIntersecting)) return;
      played = true;
      io.disconnect();
      [600, 1500, 2400].forEach((t) => setTimeout(send, t));
    },
    { threshold: 0.4 },
  ).observe(stage);
}


// ---------------------------------------------------------------------------
// Live numbers. A demo transfer of 19 files / 654 MB runs on a loop: the phone and the PC
// card count up together, ~30-40 MB/s with natural wobble, and each photo you send by tap
// nudges it on. Illustration only, labelled as such; nothing here claims a real speed.

const TOTAL = 654;
const FILES = 19;
const $ = <T extends HTMLElement>(q: string) => document.querySelector<T>(q);
const el = {
  pct: $("[data-pct]"),
  done: $("[data-done]"),
  speed: $("[data-speed]"),
  bar: $("[data-bar]"),
  eta: $("[data-eta]"),
  files: $("[data-files]"),
  thumbs: [...document.querySelectorAll<HTMLElement>("[data-thumbs] i")],
  pcFiles: $("[data-pc-files]"),
  pcBar: $("[data-pc-bar]"),
  pcDone: $("[data-pc-done]"),
  pcSpeed: $("[data-pc-speed]"),
};
let mb = 0;
let rate = 0;
let boost = 0;
let hold = 0;
let last = performance.now();

function paint() {
  const f = Math.min(1, mb / TOTAL);
  const files = Math.min(FILES, Math.floor(f * FILES + 0.0001));
  const shown = mb >= TOTAL ? "654 MB" : `${Math.round(mb)} MB`;
  if (el.pct) el.pct.textContent = String(Math.floor(f * 100));
  if (el.done) el.done.textContent = shown;
  if (el.speed) el.speed.textContent = rate.toFixed(1);
  if (el.bar) el.bar.style.transform = `scaleX(${f})`;
  if (el.files) el.files.textContent = `${files} of ${FILES}`;
  if (el.eta) el.eta.textContent = mb >= TOTAL ? "Done. Verified." : rate > 0 ? `About ${Math.max(1, Math.ceil((TOTAL - mb) / rate))} seconds left` : "Starting…";
  el.thumbs.forEach((t, i) => {
    const sky = SKIES[i % SKIES.length]!;
    t.style.backgroundImage = photo(sky);
    t.classList.toggle("is-done", files > i);
  });
  if (el.pcFiles) el.pcFiles.textContent = `${files} of ${FILES} files`;
  if (el.pcBar) el.pcBar.style.transform = `scaleX(${f})`;
  if (el.pcDone) el.pcDone.textContent = `${shown} of ${TOTAL} MB`;
  if (el.pcSpeed) el.pcSpeed.textContent = `${rate.toFixed(1)} MB/s`;
}

function tick(now: number) {
  const dt = Math.min(0.1, (now - last) / 1000);
  last = now;
  if (hold > 0) {
    hold -= dt;
    rate = 0;
    if (hold <= 0) mb = 0;
  } else {
    // Wobble around ~34 MB/s, eased so the digits roll rather than jump.
    const target = 31 + 6 * Math.sin(now / 1300) + 3 * Math.sin(now / 470) + boost;
    rate += (target - rate) * Math.min(1, dt * 3);
    boost = Math.max(0, boost - dt * 12);
    mb += rate * dt * 0.42; // ~45 s per loop: slow enough to read
    if (mb >= TOTAL) {
      mb = TOTAL;
      hold = 3.2;
    }
  }
  paint();
  requestAnimationFrame(tick);
}

if (reduced.matches) {
  mb = TOTAL * 0.38;
  rate = 34.2;
  paint();
} else {
  paint();
  requestAnimationFrame(tick);
}

/** Called when a tapped photo lands: the transfer surges a little. */
export function surge() {
  boost = 14;
  if (hold <= 0) mb = Math.min(TOTAL, mb + 8);
}


// ---------------------------------------------------------------------------
// The hero rail. Pebbles roll from the iPhone puck to the PC puck at a pace tied to the
// demo speed above; the groove fills with progress; tapping the red key throws an extra
// burst and the PC puck squash-bounces when it lands.
const groove = document.querySelector<HTMLElement>("[data-groove]");
const pebbles = [...document.querySelectorAll<HTMLElement>("[data-pebble]")];
const destPuck = document.querySelector<HTMLElement>("[data-dest]");
const PASTEL = [
  ["#f6a26b", "#c4485a"],
  ["#8fd3f4", "#4a7fb8"],
  ["#ffd27a", "#e9764f"],
  ["#b6e3a8", "#4e9a7a"],
  ["#f7c6d9", "#b56a9c"],
];
pebbles.forEach((el, i) => {
  const c = PASTEL[i % PASTEL.length]!;
  el.style.background = `radial-gradient(circle at 32% 28%, #fff8 0 8%, ${c[0]} 30%, ${c[1]})`;
});
let roll = 0;
let rollLast = performance.now();
let burstAt = -1;
function railTick(now: number) {
  const dt = Math.min(0.1, (now - rollLast) / 1000);
  rollLast = now;
  const w = groove ? groove.clientWidth : 0;
  const pace = 0.1 + 0.45 * Math.min(1, Math.log(1 + rate) / Math.log(101));
  if (hold <= 0) roll = (roll + dt * pace) % 1;
  pebbles.forEach((el, i) => {
    const u = (roll + i / pebbles.length) % 1;
    let x = 4 + (w - 34) * u;
    let y = -Math.abs(Math.sin(u * Math.PI * 6)) * 3;
    let o = hold > 0 ? 0 : Math.min(1, Math.min(u, 1 - u) / 0.08);
    if (burstAt > 0) {
      const b = (now - burstAt) / 900;
      if (b < 1 && i === 0) {
        x = 4 + (w - 34) * b * b;
        y = -Math.sin(b * Math.PI) * 26;
        o = 1;
      }
    }
    el.style.transform = `translate(${x}px, ${y}px)`;
    el.style.opacity = String(o);
  });
  if (destPuck) destPuck.classList.toggle("is-done", hold > 0);
  requestAnimationFrame(railTick);
}
if (groove && !reduced.matches) requestAnimationFrame(railTick);
const key = document.querySelector<HTMLButtonElement>(".console [data-toss]");
key?.addEventListener("click", () => {
  burstAt = performance.now();
  surge();
  setTimeout(() => {
    destPuck?.classList.remove("is-land");
    void destPuck?.offsetWidth;
    destPuck?.classList.add("is-land");
  }, 820);
});
