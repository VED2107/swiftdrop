import { formatBytes, formatCount } from "@swiftdrop/shared";
import type { TransferJob } from "@swiftdrop/transfer-engine";
import { Check, ChevronDown, FileText, Film, FolderOpen, ImageIcon, Pause, Play, RotateCcw, X } from "lucide-react";
import { memo, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Api } from "../lib/api.ts";
import { kindOf } from "../lib/files.ts";
import { markTransferUi } from "../lib/latency.ts";
import { Rail } from "./Rail.tsx";
import { notify, useApp } from "../lib/store.ts";
import type { Reading } from "../lib/reading.ts";
import { humanDuration, humanEta } from "../lib/recent.ts";
import { AnimatedNumber } from "../ui/AnimatedNumber.tsx";

const fmtPct = (v: number) => String(Math.min(100, Math.max(0, Math.floor(v))));
const fmtRate = (v: number) => (v >= 100 ? v.toFixed(0) : v.toFixed(1));

/**
 * The transfer, and nothing else. Percent and speed are the heroes; everything that
 * isn't needed right now (controls, per-file detail) waits until you reach for it.
 */
export function TransferFocus({
  r,
  rtt,
  peer,
  perspective,
  onDone,
}: {
  r: Reading;
  rtt: number | null;
  peer: string;
  perspective: "host" | "guest";
  onDone: () => void;
}) {
  const sending = r.flow === (perspective === "guest" ? "to-pc" : "to-phone");
  const jobId = r.job?.id;
  useEffect(() => {
    if (jobId) markTransferUi(jobId);
  }, [jobId]);
  if (r.state === "complete") return <Success r={r} sending={sending} host={perspective === "host"} onDone={onDone} />;

  const pct = r.bytesTotal > 0 ? (r.bytesDone / r.bytesTotal) * 100 : r.filesTotal ? (r.filesDone / r.filesTotal) * 100 : 0;
  const live = r.state === "running" || r.state === "active";
  const verb = sending ? `Sending to ${peer}` : `Receiving from ${peer}`;
  const job = r.job;
  // No bytes confirmed yet: the transfer is opening (manifest round trip, first request in
  // flight). Say so plainly instead of a vague "getting ready"; it lasts milliseconds.
  const starting = r.bytesDone === 0 && (r.state === "preparing" || r.state === "queued" || r.state === "running");

  if (r.state === "reconnecting") {
    return (
      <Calm
        title="Connection lost"
        body={`${peer === "your PC" ? "Your PC" : peer} went offline. The transfer is kept ready and continues from ${Math.floor(pct)}% as soon as it's back.`}
        action={job ? { label: "Try now", onClick: () => job.resume() } : null}
        pct={pct}
      />
    );
  }

  return (
    <section className="focus-card flex flex-col gap-8" aria-label="Transfer in progress">
      <header className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-1">
        <div className="min-w-0">
          <div className="t-small flex items-center gap-2" style={{ color: "var(--text-2)" }}>
            <span className="dot" data-state={live ? "live" : r.state === "failed" ? "warn" : undefined} />
            {r.state === "paused" ? "Paused" : r.state === "awaiting-decision" ? "Waiting for your choice" : r.state === "failed" ? "Stopped" : verb}
          </div>
          <h2 className="t-h2 mt-1 truncate">{r.title}</h2>
        </div>
        <div className="t-small num">
          {formatCount(r.filesTotal)} {r.filesTotal === 1 ? "file" : "files"} · {formatBytes(r.bytesTotal)}
        </div>
      </header>

      <div className="grid gap-8 md:grid-cols-[1fr_auto] md:items-end">
        <div>
          <div className="num leading-none" style={{ fontSize: "var(--t-hero-num)", fontWeight: 480, letterSpacing: "-0.05em" }}>
            <AnimatedNumber value={pct} format={fmtPct} />
            <span style={{ fontSize: "0.4em", color: "var(--text-3)", marginLeft: "0.08em", letterSpacing: "-0.02em" }}>%</span>
          </div>
          <div className="t-body num mt-3">
            {formatBytes(r.bytesDone)} <span style={{ color: "var(--text-4)" }}>of</span> {formatBytes(r.bytesTotal)}
          </div>
        </div>
        <div className="md:text-right">
          <div className="num leading-none" style={{ fontSize: "clamp(2rem, 1.4rem + 2vw, 2.75rem)", fontWeight: 500, letterSpacing: "-0.035em" }}>
            <AnimatedNumber value={(live ? r.speed : r.average) / 1e6} format={fmtRate} />
            <span style={{ fontSize: "0.5em", color: "var(--text-3)", marginLeft: 6, letterSpacing: "-0.01em" }}>MB/s</span>
          </div>
          <div className="t-small mt-2">{live ? "current speed" : "average speed"}</div>
        </div>
      </div>

      <div className="flex flex-col gap-3">
        <Rail
          state={r.state === "paused" ? "paused" : live ? "moving" : "linked"}
          progress={pct / 100}
          speed={r.speed}
          left={sending ? (perspective === "guest" ? "iPhone" : "PC") : peer}
          right={sending ? peer : perspective === "guest" ? "iPhone" : "PC"}
          leftKind={sending === (perspective === "guest") ? "phone" : "pc"}
          rightKind={sending === (perspective === "guest") ? "pc" : "phone"}
          label="Progress"
        />
        <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-2">
          <span className="t-small num" style={{ color: "var(--text-2)" }}>
            {r.state === "paused" ? "Paused. Nothing is lost." : starting ? "Starting…" : live ? humanEta(r.eta) : r.message ?? "…"}
          </span>
          <span className="t-small num">
            {r.peak > 0 ? `Peak ${formatBytes(r.peak)}/s` : "Measuring"}
            {rtt !== null ? ` · ${rtt.toFixed(0)} ms latency` : ""}
            {r.streams && live ? ` · ${r.streams} ${r.streams === 1 ? "stream" : "streams"}` : ""}
          </span>
        </div>
      </div>

      {job && job.direction && sending && <Thumbs job={job} />}

      {r.state === "failed" && r.message && (
        <p className="t-body" role="alert">
          {r.message}
        </p>
      )}

      {job && (
        <div className="flex flex-wrap items-center gap-2">
          {(job.state === "running" || job.state === "preparing") && (
            <button className="btn btn-secondary" onClick={() => job.pause()}>
              <Pause size={16} strokeWidth={1.75} /> Pause <span className="kbd hidden md:inline">Space</span>
            </button>
          )}
          {job.state === "paused" && (
            <button className="btn btn-primary" onClick={() => job.resume()}>
              <Play size={16} strokeWidth={1.75} /> Resume
            </button>
          )}
          {job.state === "failed" && (
            <button className="btn btn-primary" onClick={() => (job.snapshot().filesFailed ? job.retryFailed() : job.resume())}>
              <RotateCcw size={16} strokeWidth={1.75} /> Retry
            </button>
          )}
          <button className="btn btn-ghost reveal" onClick={() => void job.cancel()}>
            <X size={16} strokeWidth={1.75} /> Cancel <span className="kbd hidden md:inline">Esc</span>
          </button>
          <FileList job={job} />
        </div>
      )}
    </section>
  );
}

function Success({ r, sending, host, onDone }: { r: Reading; sending: boolean; host: boolean; onDone: () => void }) {
  const destination = useApp((s) => s.destination);
  const landedHere = host && !sending;
  const secs = r.job ? r.job.snapshot().elapsedSeconds : r.average > 0 ? r.bytesTotal / r.average : 0;
  return (
    <section className="flex flex-col items-center text-center gap-5 py-6" aria-live="polite">
      <div className="check check-done" aria-hidden>
        <svg width="34" height="34" viewBox="0 0 28 28">
          <path d="M7 14.5l4.5 4.5L21 9.5" fill="none" stroke="#fff" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>
      <div className="flex flex-col items-center gap-2">
        <h2 className="t-h1">Transfer complete</h2>
        <span className="verified">
          <Check size={14} strokeWidth={2.5} /> Verified
        </span>
        <p className="t-lead num">
          {formatCount(r.filesTotal)} {r.filesTotal === 1 ? "file" : "files"} {sending ? "sent" : "received"} · {formatBytes(r.bytesTotal)}
        </p>
        <p className="t-small num">
          Completed in {humanDuration(secs)}
          {r.average > 0 ? ` at ${formatBytes(r.average)}/s` : ""}
        </p>
      </div>
      {landedHere && (
        <p className="t-body">
          Saved to <span className="mono" style={{ color: "var(--text)" }}>{destination}</span>
        </p>
      )}
      <div className="flex flex-wrap justify-center gap-2 mt-2">
        {landedHere && (
          <button className="btn btn-primary" onClick={() => void Api.reveal(r.key).catch((e: Error) => notify(e.message, "error"))}>
            <FolderOpen size={16} strokeWidth={1.75} /> Show in folder
          </button>
        )}
        <button className={`btn ${landedHere ? "btn-secondary" : "btn-primary"} btn-lg`} onClick={onDone}>
          {sending ? "Send more" : "Done"}
        </button>
      </div>
    </section>
  );
}

function Calm({ title, body, action, pct }: { title: string; body: string; action: { label: string; onClick: () => void } | null; pct: number }) {
  return (
    <section className="flex flex-col items-center text-center gap-4 py-6" role="status">
      <div className="w-full max-w-sm bar" data-tone="paused">
        <span style={{ "--p": pct / 100 } as React.CSSProperties} />
      </div>
      <h2 className="t-h1 mt-3">{title}</h2>
      <p className="t-lead max-w-md">{body}</p>
      {action && (
        <button className="btn btn-secondary" onClick={action.onClick}>
          {action.label}
        </button>
      )}
    </section>
  );
}

/** First files of a photo transfer; each lights up as it lands. */
function Thumbs({ job }: { job: TransferJob }) {
  const count = Math.min(job.files.length, 18);
  const media = job.files.slice(0, count).filter((f) => ["image", "video"].includes(kindOf(f.name, f.type)));
  if (media.length < 3) return null;
  return (
    <div className="strip" aria-hidden>
      {job.files.slice(0, count).map((f, i) => (
        <Thumb key={f.id} file={f.blob} name={f.name} type={f.type} state={job.fileProgress(i).state === "complete" ? "done" : "pending"} />
      ))}
    </div>
  );
}

const Thumb = memo(function Thumb({ file, name, type, state }: { file: Blob; name: string; type: string; state: "done" | "pending" }) {
  const kind = kindOf(name, type);
  const [url, setUrl] = useState<string | null>(null);
  const [broken, setBroken] = useState(false);
  useEffect(() => {
    if (kind !== "image" || file.size > 30e6 || !(file instanceof File)) return;
    const u = URL.createObjectURL(file);
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [file, kind]);
  return (
    <div className="strip-cell" data-state={state}>
      {url && !broken ? <img src={url} alt="" decoding="async" onError={() => setBroken(true)} /> : kind === "video" ? <Film size={16} strokeWidth={1.5} /> : kind === "image" ? <ImageIcon size={16} strokeWidth={1.5} /> : <FileText size={16} strokeWidth={1.5} />}
    </div>
  );
});

const ROW_H = 48;

/** Per-file detail, on request. Virtualized: only visible rows exist. */
function FileList({ job }: { job: TransferJob }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const [top, setTop] = useState(0);
  const [h, setH] = useState(288);
  useLayoutEffect(() => {
    if (!open || !box.current) return;
    setH(box.current.clientHeight);
  }, [open]);
  const n = job.files.length;
  const first = Math.max(0, Math.floor(top / ROW_H) - 3);
  const last = Math.min(n, Math.ceil((top + h) / ROW_H) + 3);
  return (
    <>
      <button className="btn btn-ghost ml-auto" onClick={() => setOpen(!open)} aria-expanded={open}>
        {open ? "Hide files" : "Show files"}
        <ChevronDown size={16} strokeWidth={1.75} style={{ transform: open ? "rotate(180deg)" : undefined, transition: "transform 240ms var(--ease-out)" }} />
      </button>
      {open && (
        <div
          ref={box}
          className="w-full overflow-y-auto overscroll-contain swap-enter"
          style={{ maxHeight: 288, contain: "strict", height: Math.min(288, n * ROW_H) }}
          onScroll={(e) => setTop(e.currentTarget.scrollTop)}
        >
          <div style={{ height: n * ROW_H, position: "relative" }}>
            {Array.from({ length: last - first }, (_, k) => {
              const i = first + k;
              const f = job.files[i]!;
              const p = job.fileProgress(i);
              const frac = f.size ? p.bytes / f.size : p.state === "complete" ? 1 : 0;
              return (
                <div key={f.id} className="absolute inset-x-0 grid grid-cols-[minmax(0,1fr)_auto_96px] items-center gap-4" style={{ top: i * ROW_H, height: ROW_H, boxShadow: "0 1px 0 var(--hairline)" }}>
                  <span className="truncate t-small" style={{ color: "var(--text)" }}>
                    {f.relDir ? <span style={{ color: "var(--text-4)" }}>{f.relDir}/</span> : null}
                    {f.name}
                  </span>
                  <span className="t-micro num">{formatBytes(f.size)}</span>
                  <div className="bar" data-tone={p.state === "complete" ? "done" : undefined}>
                    <span style={{ "--p": frac } as React.CSSProperties} />
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </>
  );
}
