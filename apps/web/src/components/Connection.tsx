import { Monitor, Smartphone } from "lucide-react";
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";

export type LinkState = "waiting" | "connecting" | "connected" | "transferring";

interface DeviceSide {
  name: string;
  kind: "phone" | "pc";
  live: boolean;
}

/**
 * The product's pulse: two devices and the line between them.
 * waiting → dots drift · connecting → a wave travels · connected → a clean line with a
 * slow heartbeat · transferring → a particle stream whose speed follows real throughput.
 * Every moving part is a transform on a handful of elements.
 */
export function Connection({
  state,
  left,
  right,
  flow = "right",
  speed = 0,
  target = null,
  caption,
  compact = false,
}: {
  state: LinkState;
  left: DeviceSide;
  right: DeviceSide;
  flow?: "left" | "right";
  speed?: number;
  target?: "left" | "right" | null;
  caption?: ReactNode;
  compact?: boolean;
}) {
  const track = useRef<HTMLDivElement>(null);
  const [w, setW] = useState(400);
  useLayoutEffect(() => {
    const el = track.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setW(el.clientWidth));
    ro.observe(el);
    setW(el.clientWidth);
    return () => ro.disconnect();
  }, []);

  // Quantized so jitter in the speed reading never restarts the stream.
  const mbps = speed / 1e6;
  const bucket = mbps <= 0 ? 0 : mbps < 8 ? 1 : mbps < 40 ? 2 : mbps < 120 ? 3 : 4;
  const flowDur = [2.4, 2.2, 1.5, 0.95, 0.62][bucket]!;
  const trail = [10, 10, 14, 22, 34][bucket]!;

  return (
    <div className="flex flex-col items-center gap-4 w-full">
      <div
        className="link"
        data-flow={flow}
        style={{ "--track-w": `${w + 20}px`, "--flow-dur": `${flowDur}s`, "--pw": `${trail}px` } as React.CSSProperties}
      >
        <Device side={left} target={target === "left"} compact={compact} />
        <div ref={track} className="track" aria-hidden>
          {state === "waiting" && <div className="track-dots" />}
          {state === "connecting" && <div className="track-wave" />}
          {state === "connected" && (
            <>
              <div className="track-line" />
              <div className="track-pulse" style={flow === "left" ? { animationDirection: "reverse" } : undefined} />
            </>
          )}
          {state === "transferring" && (
            <>
              <div className="track-line" style={{ animation: "none", opacity: 0.6 }} />
              <div className="track-stream">
                {Array.from({ length: 12 }, (_, k) => (
                  <span key={k} className="particle" style={{ "--k": k, "--dy": `${[0, -3, 2, -1, 3, -2, 1, -3, 2, 0, -2, 3][k]}px` } as React.CSSProperties} />
                ))}
              </div>
            </>
          )}
        </div>
        <Device side={right} target={target === "right"} compact={compact} />
      </div>
      {caption && (
        <div className="link-caption" role="status">
          {caption}
        </div>
      )}
    </div>
  );
}

function Device({ side, target, compact }: { side: DeviceSide; target: boolean; compact: boolean }) {
  const Icon = side.kind === "phone" ? Smartphone : Monitor;
  return (
    <div className="device" data-live={side.live} data-target={target}>
      <div className="device-glyph" style={compact ? { width: 44, height: 44 } : undefined}>
        <Icon size={compact ? 18 : 21} strokeWidth={1.5} />
      </div>
      <span className="device-name">{side.name}</span>
    </div>
  );
}
