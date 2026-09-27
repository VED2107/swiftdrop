import { formatBytes, formatCount } from "@swiftdrop/shared";
import { ArrowRight, FileText, Film, ImageIcon, Plus } from "lucide-react";
import { memo, useEffect, useMemo, useState } from "react";
import { describe, kindOf, type Picked } from "../lib/files.ts";
import { storage } from "../lib/env.ts";
import { humanEta } from "../lib/recent.ts";
import { Swap } from "../ui/Swap.tsx";

/**
 * The one action when connected. Empty: an invitation to drop. Loaded: what you're
 * about to send, how big, roughly how long, and a single Send.
 */
export function Composer({
  target,
  picked,
  over,
  onChooseFiles,
  onChooseFolder,
  onSend,
  onClear,
  onReview,
}: {
  target: string;
  picked: Picked[] | null;
  over: boolean;
  onChooseFiles: () => void;
  onChooseFolder?: () => void;
  onSend: () => void;
  onClear: () => void;
  onReview: () => void;
}) {
  return (
    <Swap k={picked?.length ? "loaded" : "empty"}>
      {picked?.length ? (
        <Loaded picked={picked} target={target} onSend={onSend} onClear={onClear} onReview={onReview} />
      ) : (
        <div
          className="drop"
          data-over={over}
          role="button"
          tabIndex={0}
          onClick={onChooseFiles}
          onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && (e.preventDefault(), onChooseFiles())}
          aria-label={`Choose files to send to ${target}`}
        >
          <div className="w-12 h-12 rounded-full grid place-items-center mb-2" style={{ background: "var(--surface-2)", color: "var(--text-2)" }}>
            <Plus size={22} strokeWidth={1.5} />
          </div>
          <div className="t-h2">{over ? `Drop to send to ${target}` : "Drop anything here"}</div>
          <p className="t-small">
            or <span style={{ color: "var(--text)", textDecoration: "underline", textUnderlineOffset: 3, textDecorationColor: "var(--hairline-2)" }}>choose files</span>
            {onChooseFolder && (
              <>
                {" · "}
                <button
                  type="button"
                  className="bg-transparent border-0 p-0 cursor-pointer"
                  style={{ color: "var(--text)", textDecoration: "underline", textUnderlineOffset: 3, textDecorationColor: "var(--hairline-2)" }}
                  onClick={(e) => (e.stopPropagation(), onChooseFolder())}
                >
                  a folder
                </button>
              </>
            )}
            <span className="hidden md:inline">
              {"  "}
              <span className="kbd ml-2">Ctrl O</span>
            </span>
          </p>
        </div>
      )}
    </Swap>
  );
}

function Loaded({ picked, target, onSend, onClear, onReview }: { picked: Picked[]; target: string; onSend: () => void; onClear: () => void; onReview: () => void }) {
  const bytes = useMemo(() => picked.reduce((s, p) => s + p.file.size, 0), [picked]);
  const lastSpeed = storage.get<number>("sd.lastSpeed");
  return (
    <div className="flex flex-col items-center text-center gap-6 py-4">
      <div className="strip justify-center" style={{ maskImage: "none", WebkitMaskImage: "none" }} aria-hidden>
        {picked.slice(0, 7).map((p, i) => (
          <Mini key={i} p={p} i={i} />
        ))}
        {picked.length > 7 && (
          <div className="strip-cell t-micro num" style={{ color: "var(--text-2)" }}>
            +{formatCount(picked.length - 7)}
          </div>
        )}
      </div>
      <div className="flex flex-col gap-1">
        <div className="t-h1">{describe(picked)}</div>
        <p className="t-lead num">
          {formatCount(picked.length)} {picked.length === 1 ? "file" : "files"} · {formatBytes(bytes)}
          {lastSpeed && bytes > 20e6 ? <span style={{ color: "var(--text-3)" }}> · {humanEta(bytes / lastSpeed).replace("left", "at your usual speed")}</span> : null}
        </p>
      </div>
      <div className="flex flex-wrap items-center justify-center gap-2">
        <button className="btn btn-primary btn-lg" onClick={onSend} autoFocus>
          Send to {target} <ArrowRight size={18} strokeWidth={1.75} className="arrow" />
        </button>
        <button className="btn btn-ghost" onClick={onReview}>
          Review
        </button>
        <button className="btn btn-ghost" onClick={onClear}>
          Clear
        </button>
      </div>
    </div>
  );
}

const Mini = memo(function Mini({ p, i }: { p: Picked; i: number }) {
  const kind = kindOf(p.file.name, p.file.type);
  const [url, setUrl] = useState<string | null>(null);
  const [broken, setBroken] = useState(false);
  useEffect(() => {
    if (kind !== "image" || p.file.size > 30e6) return;
    const u = URL.createObjectURL(p.file);
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [p.file, kind]);
  const Icon = kind === "video" ? Film : kind === "image" ? ImageIcon : FileText;
  return (
    <div className="strip-cell rise" style={{ "--i": i, width: 56, height: 56 } as React.CSSProperties}>
      {url && !broken ? <img src={url} alt="" decoding="async" onError={() => setBroken(true)} /> : <Icon size={18} strokeWidth={1.5} />}
    </div>
  );
});
