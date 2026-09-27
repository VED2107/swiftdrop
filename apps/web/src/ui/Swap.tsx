import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";

/**
 * Crossfades between states keyed by `k`. The outgoing state stays mounted for its
 * exit (blur + lift, 200ms) while the incoming one enters in the same grid cell, so
 * there's no layout jump and spatial context is preserved.
 */
export function Swap({ k, children, className = "" }: { k: string; children: ReactNode; className?: string }) {
  const last = useRef<{ k: string; node: ReactNode }>({ k, node: children });
  const [leaving, setLeaving] = useState<{ k: string; node: ReactNode } | null>(null);

  useLayoutEffect(() => {
    if (last.current.k !== k) setLeaving(last.current);
    last.current = { k, node: children };
  });

  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(() => setLeaving(null), 220);
    return () => clearTimeout(t);
  }, [leaving]);

  return (
    <div className={`grid ${className}`}>
      {leaving && leaving.k !== k && (
        <div key={`out-${leaving.k}`} className="swap-exit [grid-area:1/1] min-w-0" aria-hidden inert>
          {leaving.node}
        </div>
      )}
      <div key={`in-${k}`} className="swap-enter [grid-area:1/1] min-w-0">
        {children}
      </div>
    </div>
  );
}
