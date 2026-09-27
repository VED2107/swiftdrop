import { X } from "lucide-react";
import { useEffect, useId, useRef, type ReactNode } from "react";

/** Bottom sheet on phones, centered dialog on desktop. Esc and backdrop close it. */
export function Sheet({ title, onClose, children, footer, wide = false }: { title: ReactNode; onClose: () => void; children: ReactNode; footer?: ReactNode; wide?: boolean }) {
  const id = useId();
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    panel.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      prev?.focus?.();
    };
  }, [onClose]);
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div ref={panel} tabIndex={-1} className="sheet outline-none" role="dialog" aria-modal="true" aria-labelledby={id} style={wide ? { width: "min(94vw, 760px)" } : undefined}>
        <div className="grabber" aria-hidden />
        <div className="flex items-start justify-between gap-4 px-6 pt-5 pb-2">
          <h2 id={id} className="t-h2">
            {title}
          </h2>
          <button className="btn btn-ghost btn-icon btn-sm -mr-2" onClick={onClose} aria-label="Close">
            <X size={18} strokeWidth={1.5} />
          </button>
        </div>
        <div className="px-6 pb-6 overflow-y-auto overscroll-contain grow">{children}</div>
        {footer && <div className="px-6 py-4 flex flex-wrap justify-end gap-2" style={{ boxShadow: "0 -1px 0 var(--hairline)" }}>{footer}</div>}
      </div>
    </div>
  );
}
