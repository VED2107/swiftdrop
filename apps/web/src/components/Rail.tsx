import { Monitor, Smartphone } from "lucide-react";
import { useEffect, useRef } from "react";
import { prefersReducedMotion } from "../lib/env.ts";

export type RailState = "idle" | "linked" | "moving" | "paused" | "done";

const PEBBLES = [
  ["#f6a26b", "#c4485a"],
  ["#8fd3f4", "#4a7fb8"],
  ["#ffd27a", "#e9764f"],
  ["#b6e3a8", "#4e9a7a"],
  ["#f7c6d9", "#b56a9c"],
];

/**
 * The transfer rail, same as the app's: two devices as clay pucks joined by a carved
 * groove. Idle, three pebbles wait at the start and bob; moving, pebbles roll along at a
 * pace tied to the live speed while the groove fills red behind them; done, the groove
 * turns green and the far puck bounces. `burst` fires the parked pebbles once (Send).
 */
export function Rail({
  state,
  progress = 0,
  speed = 0,
  left = "iPhone",
  right = "PC",
  leftKind = "phone",
  rightKind = "pc",
  burst = 0,
  label,
}: {
  state: RailState;
  progress?: number;
  speed?: number;
  left?: string;
  right?: string;
  leftKind?: "phone" | "pc";
  rightKind?: "phone" | "pc";
  burst?: number;
  label?: string;
}) {
  const groove = useRef<HTMLDivElement>(null);
  const pebbles = useRef<Array<HTMLSpanElement | null>>([]);
  const live = useRef({ state, speed, burstAt: -1, lastBurst: burst });
  live.current.state = state;
  live.current.speed = speed;
  if (burst !== live.current.lastBurst) {
    live.current.lastBurst = burst;
    live.current.burstAt = performance.now();
  }

  useEffect(() => {
    if (prefersReducedMotion()) return;
    let raf = 0;
    let phase = 0;
    let last = performance.now();
    const tick = (now: number) => {
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      const g = groove.current;
      const w = g ? g.clientWidth : 0;
      const { state: s, speed: sp, burstAt } = live.current;
      if (s === "moving") {
        const mbps = sp / 1e6;
        phase = (phase + dt * (0.12 + 0.48 * Math.min(1, Math.log(1 + mbps) / Math.log(101)))) % 1;
      }
      pebbles.current.forEach((el, i) => {
        if (!el) return;
        let x: number;
        let y: number;
        let o = 1;
        if (s === "moving") {
          const n = pebbles.current.length;
          const u = (phase + i / n) % 1;
          x = 6 + (w - 34) * u;
          y = -Math.abs(Math.sin(u * Math.PI * 6)) * 3;
          o = Math.min(1, Math.min(u, 1 - u) / 0.08);
        } else if (i < 3 && (s === "idle" || s === "linked" || s === "paused")) {
          x = 8 + i * 22;
          y = -Math.abs(Math.sin(now / 420 + i * 1.3)) * 2.4;
          if (burstAt > 0) {
            const b = (now - burstAt) / 1400;
            if (b < 1) {
              const local = Math.max(0, Math.min(1, (b - i * 0.08) / 0.62));
              const eased = local * local * local;
              if (b < 0.7) {
                x = x + (w - 34 - x) * eased;
                y = -Math.sin(local * Math.PI) * 18;
              } else {
                o = (b - 0.7) / 0.3;
              }
            }
          }
        } else {
          o = 0;
          x = 0;
          y = 0;
        }
        el.style.transform = `translate(${x}px, ${y}px)`;
        el.style.opacity = String(o);
      });
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, []);

  const fill = state === "done" ? 1 : state === "linked" || state === "idle" ? 0 : progress;
  const Icon = (k: "phone" | "pc") => (k === "phone" ? <Smartphone size={22} strokeWidth={1.75} /> : <Monitor size={22} strokeWidth={1.75} />);
  return (
    <div className="rail" data-state={state} data-burst={burst}>
      <div className="puck" data-lit="true">
        {Icon(leftKind)}
        <span className="puck-name">{left}</span>
      </div>
      <div
        className="groove"
        ref={groove}
        role={state === "moving" || state === "paused" ? "progressbar" : undefined}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={Math.floor(fill * 100)}
        aria-label={label ?? "Progress"}
      >
        <span className="groove-fill" style={{ transform: `scaleX(${fill})` }} />
        <span className="groove-ticks" aria-hidden />
        {PEBBLES.map((c, i) => (
          <span
            key={i}
            ref={(el) => {
              pebbles.current[i] = el;
            }}
            className="pebble"
            aria-hidden
            style={{ background: `radial-gradient(circle at 32% 28%, #fff8 0 8%, ${c[0]} 30%, ${c[1]})`, opacity: i < 3 ? 1 : 0, transform: `translate(${8 + i * 22}px, 0)` }}
          />
        ))}
      </div>
      <div className="puck" data-lit={state !== "idle"} data-land={state === "done" ? "true" : undefined}>
        {Icon(rightKind)}
        <span className="puck-name">{right}</span>
      </div>
    </div>
  );
}
