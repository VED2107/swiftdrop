import { useEffect, useRef } from "react";
import { prefersReducedMotion } from "../lib/env.ts";

/**
 * A number that glides to its target on a critically damped spring. Writes to the DOM
 * directly (no React render per frame) and stops its rAF loop once settled, so a 4 Hz
 * data feed reads as continuous motion without costing the transfer anything.
 */
export function AnimatedNumber({
  value,
  format,
  className,
}: {
  value: number;
  format: (v: number) => string;
  className?: string;
}) {
  const el = useRef<HTMLSpanElement>(null);
  const state = useRef({ x: value, v: 0, target: value, raf: 0, last: 0 });
  const fmt = useRef(format);
  fmt.current = format;

  useEffect(() => {
    const s = state.current;
    s.target = Number.isFinite(value) ? value : 0;
    if (prefersReducedMotion()) {
      s.x = s.target;
      if (el.current) el.current.textContent = fmt.current(s.x);
      return;
    }
    if (s.raf) return;
    s.last = performance.now();
    const step = (now: number) => {
      const dt = Math.min(0.05, (now - s.last) / 1000);
      s.last = now;
      // critically damped: ω = 9 rad/s → settles in ~0.5s
      const w = 9;
      const a = -2 * w * s.v - w * w * (s.x - s.target);
      s.v += a * dt;
      s.x += s.v * dt;
      if (Math.abs(s.x - s.target) < Math.abs(s.target) * 0.0005 + 0.0005 && Math.abs(s.v) < 0.01) {
        s.x = s.target;
        s.v = 0;
        s.raf = 0;
      } else {
        s.raf = requestAnimationFrame(step);
      }
      if (el.current) el.current.textContent = fmt.current(s.x);
    };
    s.raf = requestAnimationFrame(step);
  }, [value]);

  useEffect(() => () => cancelAnimationFrame(state.current.raf), []);

  return (
    <span ref={el} className={className}>
      {format(value)}
    </span>
  );
}
