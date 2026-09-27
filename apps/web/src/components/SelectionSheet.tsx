import { formatBytes, formatCount } from "@swiftdrop/shared";
import { humanEta } from "../lib/recent.ts";
import { ArrowRight, Check, FileArchive, FileAudio, FileText, File as FileIcon, Film, ImageIcon } from "lucide-react";
import { memo, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { storage } from "../lib/env.ts";
import { kindOf, type Kind, type Picked } from "../lib/files.ts";

interface Props {
  picked: Picked[];
  target: string;
  onSend: (files: Picked[]) => void;
  onClose: () => void;
}

const GAP = 8;
const LABEL_H = 38;

/**
 * Review before sending. Virtualized: only visible rows exist, and only visible images
 * get an object URL, so 10,000 photos cost ~40 decoded thumbnails, not 10,000.
 */
export function SelectionSheet({ picked, target, onSend, onClose }: Props) {
  const [selected, setSelected] = useState(() => new Uint8Array(picked.length).fill(1));
  const scroller = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState({ width: 360, height: 400, top: 0 });

  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const measure = () => setBox((b) => ({ ...b, width: el.clientWidth, height: el.clientHeight }));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    let raf = 0;
    const onScroll = () => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => setBox((b) => ({ ...b, top: el.scrollTop })));
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      ro.disconnect();
      el.removeEventListener("scroll", onScroll);
      cancelAnimationFrame(raf);
    };
  }, []);

  const cols = Math.max(3, Math.floor((box.width + GAP) / (104 + GAP)));
  const tile = (box.width - GAP * (cols - 1)) / cols;
  const rowH = tile + LABEL_H + GAP;
  const rows = Math.ceil(picked.length / cols);
  const first = Math.max(0, Math.floor(box.top / rowH) - 2);
  const last = Math.min(rows, Math.ceil((box.top + box.height) / rowH) + 2);

  const totals = useMemo(() => {
    let n = 0;
    let bytes = 0;
    for (let i = 0; i < picked.length; i++)
      if (selected[i]) {
        n++;
        bytes += picked[i]!.file.size;
      }
    return { n, bytes };
  }, [picked, selected]);

  const lastSpeed = storage.get<number>("sd.lastSpeed");
  const toggle = (i: number) => {
    selected[i] = selected[i] ? 0 : 1;
    setSelected(selected.slice());
  };
  const setAll = (v: 0 | 1) => setSelected(new Uint8Array(picked.length).fill(v));

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="scrim" role="presentation">
      <div className="sheet" role="dialog" aria-modal="true" aria-labelledby="sel-title" style={{ height: "min(88dvh, 760px)" }}>
        <div className="grabber" aria-hidden />
        <div className="px-6 pt-5 pb-4 flex items-start justify-between gap-4">
          <div>
            <h2 id="sel-title" className="t-h2">
              Send to {target}
            </h2>
            <p className="t-small num mt-1">
              {formatCount(totals.n)} of {formatCount(picked.length)} selected · {formatBytes(totals.bytes)}
              {lastSpeed && totals.bytes > 20e6 ? ` · ${humanEta(totals.bytes / lastSpeed).replace("left", "at your usual speed")}` : ""}
            </p>
          </div>
          <div className="flex gap-1 shrink-0">
            <button className="btn btn-ghost btn-sm" onClick={() => (totals.n === picked.length ? setAll(0) : setAll(1))}>
              {totals.n === picked.length ? "Select none" : "Select all"}
            </button>
          </div>
        </div>

        <div ref={scroller} className="grow overflow-y-auto px-6 overscroll-contain" style={{ contain: "strict" }}>
          <div style={{ height: rows * rowH, position: "relative" }}>
            {Array.from({ length: last - first }, (_, k) => {
              const r = first + k;
              return (
                <div key={r} className="absolute left-0 right-0 flex" style={{ top: r * rowH, gap: GAP }}>
                  {Array.from({ length: cols }, (_, c) => {
                    const i = r * cols + c;
                    if (i >= picked.length) return <div key={c} style={{ width: tile }} />;
                    return <Tile key={i} p={picked[i]!} size={tile} on={Boolean(selected[i])} onToggle={() => toggle(i)} />;
                  })}
                </div>
              );
            })}
          </div>
        </div>

        <div className="px-6 py-4 flex flex-col-reverse sm:flex-row gap-2 sm:justify-end" style={{ boxShadow: "0 -1px 0 var(--hairline)" }}>
          <button className="btn btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn-primary btn-lg"
            disabled={totals.n === 0}
            onClick={() => onSend(picked.filter((_, i) => selected[i]))}
          >
            Send {formatCount(totals.n)} {totals.n === 1 ? "item" : "items"} <ArrowRight size={18} strokeWidth={1.75} className="arrow" />
          </button>
        </div>
      </div>
    </div>
  );
}

const ICONS: Record<Kind, typeof FileIcon> = {
  image: ImageIcon,
  video: Film,
  audio: FileAudio,
  archive: FileArchive,
  document: FileText,
  other: FileIcon,
};

const Tile = memo(function Tile({ p, size, on, onToggle }: { p: Picked; size: number; on: boolean; onToggle: () => void }) {
  const kind = kindOf(p.file.name, p.file.type);
  const [url, setUrl] = useState<string | null>(null);
  const [broken, setBroken] = useState(false);
  useEffect(() => {
    if (kind !== "image" || p.file.size > 40e6) return;
    const u = URL.createObjectURL(p.file);
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [p.file, kind]);
  const Icon = ICONS[kind];
  return (
    <button
      type="button"
      onClick={onToggle}
      aria-pressed={on}
      className="text-left cursor-pointer p-0 bg-transparent border-0 transition-transform active:scale-[0.97]"
      style={{ width: size, color: "var(--text)" }}
      title={p.file.name}
    >
      <div className="thumb" style={{ boxShadow: on ? "inset 0 0 0 2px var(--accent)" : "inset 0 0 0 1px var(--hairline)", opacity: on ? 1 : 0.55, transition: "opacity 200ms ease, box-shadow 200ms ease" }}>
        {url && !broken ? (
          <img src={url} alt="" loading="lazy" decoding="async" onError={() => setBroken(true)} />
        ) : (
          <div className="w-full h-full grid place-items-center" style={{ color: "var(--text-4)" }}>
            <Icon size={Math.round(size / 3.5)} strokeWidth={1.25} />
          </div>
        )}
        <span
          className="absolute top-1.5 right-1.5 w-6 h-6 rounded-full grid place-items-center"
          style={{ background: on ? "var(--accent)" : "oklch(0 0 0 / 0.45)", color: "var(--accent-ink)", boxShadow: on ? "none" : "inset 0 0 0 1.5px oklch(1 0 0 / 0.7)", transition: "background-color 160ms ease" }}
        >
          {on && <Check size={14} strokeWidth={3} />}
        </span>
        {kind === "video" && (
          <span className="absolute bottom-1.5 left-1.5 t-micro px-1.5 rounded" style={{ background: "oklch(0 0 0 / 0.55)", color: "white" }}>
            Video
          </span>
        )}
      </div>
      <div className="t-micro mt-1.5 truncate" style={{ color: "var(--text-2)" }}>{p.file.name}</div>
      <div className="t-micro num" style={{ color: "var(--text-4)" }}>
        {formatBytes(p.file.size)}
      </div>
    </button>
  );
});
