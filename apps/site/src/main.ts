import "./site.css";
import downloadIcon from "@phosphor-icons/core/assets/bold/download-simple-bold.svg?raw";

const DOWNLOAD_URL: string = import.meta.env.VITE_DOWNLOAD_URL || "https://github.com/VED2107/swiftdrop/releases/latest";
const reduced = matchMedia("(prefers-reduced-motion: reduce)");
const TICK = `<svg class="tick" viewBox="0 0 100 100" aria-hidden="true"><path pathLength="1" d="M16 56 L40 80 L86 20" /></svg>`;
const PHOTOS = Array.from({ length: 14 }, (_, i) => `/frames/f${String(i + 1).padStart(2, "0")}.webp`);

for (const a of document.querySelectorAll<HTMLAnchorElement>("[data-download]")) a.href = DOWNLOAD_URL;
for (const el of document.querySelectorAll<HTMLElement>('[data-icon="download"]')) el.innerHTML = downloadIcon;

// On a phone the download isn't for this device: say so instead of offering a .exe.
if (/iPhone|iPad|Android/.test(navigator.userAgent)) {
  for (const n of document.querySelectorAll("[data-platform-note]")) n.textContent = "Download it on your Windows PC, then scan its code with this phone.";
}

function frame(src: string, no: number, eager = false): HTMLLIElement {
  const li = document.createElement("li");
  li.className = "frame";
  li.innerHTML = `<div class="frame-img"><img src="${src}" width="640" height="480" alt="" ${eager ? "" : 'loading="lazy"'} decoding="async" />${TICK}</div><span class="frame-no edge num">${no}</span>`;
  return li;
}

/** Run `fn` each time `el` scrolls into view (or once, then stop). */
function onView(el: Element, fn: () => void, once = true, threshold = 0.35) {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        fn();
        if (once) io.disconnect();
      }
    },
    { threshold },
  );
  io.observe(el);
  return io;
}

// ---------------------------------------------------------------------------
// Hero roll. Frames advance one at a time, phone side to PC side, like film through a
// camera; each frame that passes the red gate gets its grease-pencil tick.

const roll = document.querySelector<HTMLElement>("[data-roll]");
const track = document.querySelector<HTMLOListElement>("[data-track]");
if (roll && track) {
  let next = PHOTOS.length;
  // Rightmost frame is the lowest number: it reached the PC first.
  for (let i = 0; i < PHOTOS.length; i++) track.append(frame(PHOTOS[i]!, PHOTOS.length - i, true));
  const gate = roll.querySelector<HTMLElement>(".gate")!;
  let step = 0;

  const measure = () => {
    const f = track.firstElementChild as HTMLElement;
    step = f.getBoundingClientRect().width + parseFloat(getComputedStyle(track).columnGap || "0");
    track.style.transform = `translateX(${-step}px)`;
  };
  const tickPast = (animate: boolean) => {
    const gx = gate.getBoundingClientRect().left;
    for (const li of track.children as HTMLCollectionOf<HTMLElement>) {
      const r = li.getBoundingClientRect();
      const past = r.left + r.width * 0.5 > gx;
      if (past && !li.classList.contains("is-ticked")) {
        if (!animate) (li.querySelector(".tick path") as SVGPathElement).style.transition = "none";
        li.classList.add("is-ticked");
        if (!animate) requestAnimationFrame(() => ((li.querySelector(".tick path") as SVGPathElement).style.transition = ""));
      }
    }
  };

  measure();
  tickPast(false);
  new ResizeObserver(() => {
    measure();
    tickPast(false);
  }).observe(roll);

  let running = false;
  let visible = true;
  const advance = async () => {
    if (running) return;
    running = true;
    const anim = track.animate([{ transform: `translateX(${-step}px)` }, { transform: "translateX(0px)" }], {
      duration: 720,
      easing: "cubic-bezier(0.77, 0, 0.175, 1)",
    });
    await anim.finished.catch(() => undefined);
    // The frame that left on the right comes back round on the phone side as the next photo.
    const last = track.lastElementChild as HTMLElement;
    last.classList.remove("is-ticked");
    last.querySelector(".frame-no")!.textContent = String(++next);
    track.prepend(last);
    track.style.transform = `translateX(${-step}px)`;
    tickPast(true);
    running = false;
  };

  let timer: ReturnType<typeof setInterval> | null = null;
  const sync = () => {
    const go = visible && !reduced.matches && document.visibilityState === "visible";
    if (go && !timer) timer = setInterval(() => void advance(), 1700);
    if (!go && timer) {
      clearInterval(timer);
      timer = null;
    }
  };
  new IntersectionObserver(([e]) => {
    visible = Boolean(e?.isIntersecting);
    sync();
  }).observe(roll);
  document.addEventListener("visibilitychange", sync);
  reduced.addEventListener("change", sync);
  sync();
}

// ---------------------------------------------------------------------------
// Prints: each screen of the app gets its tick as the sheet comes into view.

const prints = [...document.querySelectorAll<SVGElement>(".print .tick")];
if (prints.length) {
  onView(document.querySelector(".prints")!, () =>
    prints.forEach((t, i) => (reduced.matches ? t.classList.add("is-drawn") : setTimeout(() => t.classList.add("is-drawn"), 220 + i * 160))),
  );
}

// ---------------------------------------------------------------------------
// Resume strip: frames 1-4 arrive, the line breaks, then 5-9 follow. Nothing restarts.

const cut = document.querySelector<HTMLElement>("[data-cut]");
if (cut) {
  const pieces = { a: [1, 2, 3, 4], b: [5, 6, 7, 8, 9] };
  for (const [key, nums] of Object.entries(pieces)) {
    const piece = cut.querySelector<HTMLElement>(`[data-piece="${key}"]`)!;
    const frames = document.createElement("ol");
    frames.className = "frames";
    frames.style.cssText = "list-style:none;margin:0";
    for (const n of nums) frames.append(frame(PHOTOS[(n + 3) % PHOTOS.length]!, n));
    piece.append(Object.assign(document.createElement("div"), { className: "rebate rebate-top" }), frames, Object.assign(document.createElement("div"), { className: "rebate rebate-bottom" }));
  }
  const all = [...cut.querySelectorAll<HTMLElement>(".frame")];
  onView(
    cut,
    () => {
      if (reduced.matches) {
        all.forEach((f) => f.classList.add("is-ticked"));
        cut.classList.add("is-cut");
        return;
      }
      let t = 150;
      all.forEach((f, i) => {
        if (i === 4) {
          setTimeout(() => cut.classList.add("is-cut"), t);
          t += 700; // the drop: a beat of nothing, then it picks up at frame 5
        }
        setTimeout(() => f.classList.add("is-ticked"), t);
        t += 190;
      });
    },
    true,
    0.5,
  );
}

// ---------------------------------------------------------------------------
// Privacy: the one word that matters gets underlined.

const marked = document.querySelector(".marked");
if (marked) onView(marked, () => marked.classList.add("is-drawn"), true, 0.8);
