import { describePath, pathLabel, PEER_CONTROLLER, PeerReceiver, PeerSession, PeerTransport, type IncomingOffer, type PathInfo, type ReceivedTransfer } from "@swiftdrop/peer";
import { formatBytes, formatCount } from "@swiftdrop/shared";
import { TransferJob } from "@swiftdrop/transfer-engine";
import { ArrowDownToLine, ArrowUpFromLine, Check, Download, RefreshCw, ScanLine, Share, Wifi } from "lucide-react";
import QRCode from "qrcode";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { QrCode } from "../components/QrCode.tsx";
import { canShareFiles, deviceName } from "../lib/env.ts";
import { describe, fromInput, toSources, type Picked } from "../lib/files.ts";
import { Logo } from "../ui/Logo.tsx";
import { OpfsSinkFactory, OpfsStateStore, opfsAvailable } from "./opfs.ts";
import { Scanner } from "./Scanner.tsx";

/**
 * Phone ↔ phone, direct. No PC, no server: the two phones swap one QR each (SDP only),
 * then every byte goes over a WebRTC DataChannel between them.
 */

type Stage =
  | { k: "home" }
  | { k: "send-offer"; link: string }
  | { k: "send-scan" }
  | { k: "recv-scan" }
  | { k: "recv-answer"; link: string }
  | { k: "connecting" }
  | { k: "transfer" }
  | { k: "lost" };

/** Benchmark knobs (`?hw=<KiB>&frame=<KiB>`): send-buffer high-water mark and frame size. */
const knobs = new URLSearchParams(location.search);
const framing = {
  ...(knobs.get("hw") ? { highWaterMark: Number(knobs.get("hw")) * 1024, lowWaterMark: (Number(knobs.get("hw")) * 1024) / 4 } : {}),
  ...(knobs.get("frame") ? { maxMessageSize: Number(knobs.get("frame")) * 1024 } : {}),
};

const channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel("swiftdrop-p2p");
const initialOffer = /[#&]o=([DP][A-Za-z0-9_-]+)/.exec(location.hash)?.[1] ?? null;
const initialAnswer = /[#&]a=([DP][A-Za-z0-9_-]+)/.exec(location.hash)?.[1] ?? null;
if (initialOffer || initialAnswer) history.replaceState(null, "", location.pathname + location.search);

export function P2PApp() {
  const [role, setRole] = useState<"send" | "receive" | null>(initialOffer ? "receive" : null);
  const [stage, setStage] = useState<Stage>({ k: "home" });
  const [picked, setPicked] = useState<Picked[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [path, setPath] = useState<PathInfo | null>(null);
  const [peerName, setPeerName] = useState("");
  const [offer, setOffer] = useState<{ offer: IncomingOffer; decide: (ok: boolean) => void } | null>(null);
  const [, setTick] = useState(0);
  const filesInput = useRef<HTMLInputElement>(null);
  const session = useRef<PeerSession | null>(null);
  const transport = useRef(new PeerTransport());
  const job = useRef<TransferJob | null>(null);
  const sinks = useMemo(() => (opfsAvailable() ? new OpfsSinkFactory() : null), []);
  const receiver = useMemo(
    () =>
      sinks
        ? new PeerReceiver({
            sinks,
            state: new OpfsStateStore(),
            accept: (o) => new Promise<boolean>((resolve) => setOffer({ offer: o, decide: (ok) => (setOffer(null), resolve(ok ? enoughSpace(o) : Promise.resolve(false))) })),
          })
        : null,
    [sinks],
  );
  const name = useMemo(() => deviceName(), []);

  // Repaint progress on a clock, like the rest of the app; nothing renders per chunk.
  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), 250);
    return () => clearInterval(t);
  }, []);

  const fail = useCallback((e: unknown) => setError(e instanceof Error ? e.message : String(e)), []);

  /** A DataChannel is open: hand it to whichever side this phone plays. */
  const connected = useCallback(
    async (s: PeerSession, as: "send" | "receive") => {
      const link = await s.transport();
      setPeerName(s.remoteName);
      setStage({ k: "transfer" });
      link.onClose(() => {
        const j = job.current;
        const receiving = as === "receive" && receiver?.list().some((t) => t.filesDone < t.files.length);
        if ((j && !["complete", "cancelled", "failed"].includes(j.state)) || receiving) setStage({ k: "lost" });
      });
      void refreshPath(s, setPath);
      if (as === "send") {
        transport.current.attach(link);
        if (!job.current) {
          const j = new TransferJob({ transport: transport.current, files: toSources(picked), direction: "to-peer", label: describe(picked), controller: PEER_CONTROLLER });
          job.current = j;
          void j.start();
        }
      } else {
        receiver!.attach(link);
      }
    },
    [picked, receiver],
  );

  // ---- sender ----------------------------------------------------------------
  const makeOffer = useCallback(async () => {
    setError(null);
    try {
      session.current?.close();
      const { session: s, offer } = await PeerSession.offer({ name, framing });
      session.current = s;
      setStage({ k: "send-offer", link: `${location.origin}${location.pathname}#o=${offer}` });
    } catch (e) {
      fail(e);
    }
  }, [name, fail]);

  const takeAnswer = useCallback(
    async (text: string) => {
      setError(null);
      try {
        const s = session.current!;
        await s.accept(text);
        setStage({ k: "connecting" });
        await connected(s, "send");
      } catch (e) {
        fail(e);
        setStage({ k: "send-scan" });
      }
    },
    [connected, fail],
  );

  // A reply scanned with the Camera app opens in a new tab: it hands the answer back here.
  useEffect(() => {
    if (!channel) return;
    const on = (ev: MessageEvent<{ answer?: string }>) => ev.data.answer && session.current && void takeAnswer(ev.data.answer);
    channel.addEventListener("message", on);
    return () => channel.removeEventListener("message", on);
  }, [takeAnswer]);

  // ---- receiver --------------------------------------------------------------
  const takeOffer = useCallback(
    async (text: string) => {
      setError(null);
      try {
        session.current?.close();
        const { session: s, answer } = await PeerSession.answer(text, { name, framing });
        session.current = s;
        setPeerName(s.remoteName);
        setStage({ k: "recv-answer", link: `${location.origin}${location.pathname}#a=${answer}` });
        void navigator.storage?.persist?.().catch(() => undefined);
        await connected(s, "receive");
      } catch (e) {
        fail(e);
        setStage({ k: "recv-scan" });
      }
    },
    [name, connected, fail],
  );

  useEffect(() => {
    if (initialOffer) void takeOffer(initialOffer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useWakeLock(stage.k === "transfer");

  if (initialAnswer) return <Handoff answer={initialAnswer} />;

  const j = job.current;
  const incoming = receiver?.list().sort((a, b) => b.createdAt - a.createdAt)[0] ?? null;

  return (
    <div className="min-h-dvh flex flex-col" style={{ background: "var(--bg)" }}>
      <header className="flex items-center justify-between px-5 pt-5">
        <div className="flex items-center gap-2">
          <Logo />
          <span className="t-small">Phone to phone</span>
        </div>
        {path && <PathBadge path={path} />}
      </header>

      <main className="flex-1 w-full max-w-[460px] mx-auto px-5 py-8 flex flex-col gap-8" aria-live="polite">
        {!isSecureContext && (
          <p className="t-small" role="alert">
            This page must be opened over https for phone-to-phone transfers (camera and file storage need it).
          </p>
        )}
        {error && (
          <p className="t-small" role="alert" style={{ color: "var(--danger, #e5484d)" }}>
            {error}
          </p>
        )}

        {stage.k === "home" && !role && (
          <>
            <div className="flex flex-col gap-3">
              <h1 className="t-display">Phone to phone.</h1>
              <p className="t-lead">Directly between two phones on the same Wi-Fi or hotspot. No PC, no cloud.</p>
            </div>
            <div className="grid gap-3">
              <button className="btn btn-primary" onClick={() => (setRole("send"), filesInput.current?.click())}>
                <ArrowUpFromLine size={18} /> Send
              </button>
              <button className="btn btn-secondary" disabled={!receiver} onClick={() => (setRole("receive"), setStage({ k: "recv-scan" }))}>
                <ArrowDownToLine size={18} /> Receive
              </button>
              {!receiver && <p className="t-small">This browser can't store received files (it needs https and file-system storage).</p>}
            </div>
          </>
        )}

        {role === "send" && stage.k === "home" && (
          <div className="flex flex-col gap-4">
            <h1 className="t-h1">{picked.length ? `${formatCount(picked.length)} ${picked.length === 1 ? "file" : "files"} · ${formatBytes(picked.reduce((s, p) => s + p.file.size, 0))}` : "Choose files"}</h1>
            <button className="btn btn-secondary" onClick={() => filesInput.current?.click()}>
              {picked.length ? "Choose different files" : "Choose files"}
            </button>
            {picked.length > 0 && (
              <button className="btn btn-primary" onClick={() => void makeOffer()}>
                Show code to the other phone
              </button>
            )}
          </div>
        )}

        {stage.k === "send-offer" && (
          <SignalCard
            title="Scan this with the other phone"
            hint="Its Camera app works, or tap Receive in SwiftDrop there."
            link={stage.link}
            action={
              <button className="btn btn-primary" onClick={() => setStage({ k: "send-scan" })}>
                <ScanLine size={18} /> Scan its reply
              </button>
            }
          />
        )}
        {stage.k === "send-scan" && (
          <div className="flex flex-col gap-4">
            <h1 className="t-h1">Scan the reply</h1>
            <Scanner hint="Point at the code the other phone shows now." onResult={(t) => void takeAnswer(t)} />
          </div>
        )}

        {stage.k === "recv-scan" && (
          <div className="flex flex-col gap-4">
            <h1 className="t-h1">Scan the sender's code</h1>
            <Scanner hint="On the sending phone: Send, pick files, Show code." onResult={(t) => void takeOffer(t)} />
          </div>
        )}
        {stage.k === "recv-answer" && (
          <SignalCard title={`Show this to ${peerName || "the sender"}`} hint="It taps Scan its reply and points its camera here." link={stage.link} />
        )}

        {stage.k === "connecting" && <p className="t-lead">Connecting directly…</p>}

        {stage.k === "lost" && (
          <div className="flex flex-col gap-4">
            <h1 className="t-h1">Connection lost</h1>
            <p className="t-body">Nothing received so far is lost. Connect again and it carries on from where it stopped.</p>
            {role === "send" ? (
              <button className="btn btn-primary" onClick={() => void makeOffer()}>
                <RefreshCw size={18} /> Reconnect
              </button>
            ) : (
              <button className="btn btn-primary" onClick={() => setStage({ k: "recv-scan" })}>
                <ScanLine size={18} /> Scan the new code
              </button>
            )}
          </div>
        )}

        {offer && <AcceptCard offer={offer.offer} from={peerName} onDecide={offer.decide} />}

        {stage.k === "transfer" && role === "send" && j && <SendProgress job={j} peer={peerName} />}
        {(stage.k === "transfer" || stage.k === "lost") && role === "receive" && incoming && !offer && <ReceiveProgress t={incoming} receiver={receiver!} peer={peerName} />}
      </main>

      <input
        ref={filesInput}
        type="file"
        multiple
        hidden
        onChange={(e) => {
          const p = fromInput(e.target.files);
          e.target.value = "";
          if (p.length) setPicked(p);
          else if (!picked.length) setRole(null);
        }}
      />
    </div>
  );
}

function SignalCard({ title, hint, link, action }: { title: string; hint: string; link: string; action?: React.ReactNode }) {
  const qr = useMemo(() => {
    const m = QRCode.create(link, { errorCorrectionLevel: "L" }).modules;
    let s = "";
    for (let i = 0; i < m.data.length; i++) s += String.fromCharCode(m.data[i]!);
    return { size: m.size, bits: btoa(s) };
  }, [link]);
  return (
    <div className="flex flex-col gap-5 items-center text-center">
      <h1 className="t-h1">{title}</h1>
      <div data-testid="signal" data-signal={link} className="w-full max-w-[340px] p-4" style={{ background: "#fff", borderRadius: 28, aspectRatio: "1" }}>
        <QrCode size={qr.size} bits={qr.bits} label={title} />
      </div>
      <p className="t-small">{hint}</p>
      {action}
    </div>
  );
}

function AcceptCard({ offer, from, onDecide }: { offer: IncomingOffer; from: string; onDecide: (ok: boolean) => void }) {
  return (
    <div className="flex flex-col gap-4" role="dialog" aria-label="Incoming files">
      <h1 className="t-h1">
        {from || "A phone"} wants to send {formatCount(offer.files.length)} {offer.files.length === 1 ? "file" : "files"}
      </h1>
      <p className="t-lead num">{formatBytes(offer.totalBytes)}</p>
      <ul className="t-small flex flex-col gap-1 max-h-48 overflow-auto">
        {offer.files.slice(0, 50).map((f) => (
          <li key={f.id} className="truncate">
            {f.relDir ? `${f.relDir}/` : ""}
            {f.name}
          </li>
        ))}
        {offer.files.length > 50 && <li>…and {formatCount(offer.files.length - 50)} more</li>}
      </ul>
      <div className="grid grid-cols-2 gap-3">
        <button className="btn btn-secondary" onClick={() => onDecide(false)}>
          Decline
        </button>
        <button className="btn btn-primary" onClick={() => onDecide(true)}>
          Accept
        </button>
      </div>
    </div>
  );
}

function SendProgress({ job, peer }: { job: TransferJob; peer: string }) {
  const s = job.snapshot();
  const pct = s.bytesTotal ? (s.bytesDone / s.bytesTotal) * 100 : 100;
  const title =
    s.state === "complete"
      ? "Sent"
      : s.state === "failed"
        ? (s.message ?? "Transfer failed")
        : s.state === "preparing"
          ? `Waiting for ${peer || "the other phone"} to accept…`
          : s.state === "reconnecting"
            ? "Reconnecting…"
            : `Sending to ${peer || "the other phone"}`;
  return (
    <div className="flex flex-col gap-4" data-testid="send-progress" data-state={s.state}>
      <h1 className="t-h1">{title}</h1>
      <Bar pct={pct} />
      <p className="t-small num">
        {formatBytes(s.bytesDone)} of {formatBytes(s.bytesTotal)}
        {s.state === "running" && s.speed > 0 ? ` · ${formatBytes(s.speed)}/s` : ""}
        {s.state === "complete" && s.average > 0 ? ` · average ${formatBytes(s.average)}/s` : ""}
      </p>
    </div>
  );
}

function ReceiveProgress({ t, receiver, peer }: { t: ReceivedTransfer; receiver: PeerReceiver; peer: string }) {
  const done = t.filesDone === t.files.length;
  const speed = useRate(t.bytesDone);
  const [saving, setSaving] = useState(false);
  const saveAll = async () => {
    setSaving(true);
    try {
      const files = await Promise.all(t.files.map((f) => receiver.file(t, f)));
      if (canShareFiles(files)) await navigator.share({ files }).catch(() => undefined);
      else for (const f of files) download(f);
    } finally {
      setSaving(false);
    }
  };
  return (
    <div className="flex flex-col gap-4" data-testid="receive-progress" data-state={done ? "complete" : "active"}>
      <h1 className="t-h1">{done ? `Received from ${peer || "the other phone"}` : `Receiving from ${peer || "the other phone"}`}</h1>
      <Bar pct={t.bytesTotal ? (t.bytesDone / t.bytesTotal) * 100 : 100} />
      <p className="t-small num">
        {formatCount(t.filesDone)} of {formatCount(t.files.length)} files · {formatBytes(t.bytesDone)} of {formatBytes(t.bytesTotal)}
        {!done && speed > 0 ? ` · ${formatBytes(speed)}/s` : ""}
      </p>
      {done && (
        <>
          <button className="btn btn-primary" disabled={saving} onClick={() => void saveAll()}>
            <Share size={18} /> {t.files.length === 1 ? "Save" : "Save all"}
          </button>
          <ul className="flex flex-col">
            {t.files.map((f) => (
              <li key={f.id} className="row">
                <span className="truncate min-w-0">{[...f.relDir, f.name].join("/")}</span>
                <span className="t-small num">{formatBytes(f.size)}</span>
                <button className="btn btn-ghost btn-sm" aria-label={`Download ${f.name}`} onClick={() => void receiver.file(t, f).then(download)}>
                  <Download size={15} />
                </button>
              </li>
            ))}
          </ul>
          <p className="t-small">Files stay in this browser's storage until you save them. Received with checks on every block.</p>
        </>
      )}
    </div>
  );
}

function Bar({ pct }: { pct: number }) {
  return (
    <div style={{ height: 6, borderRadius: 3, background: "var(--surface-2)", overflow: "hidden" }} role="progressbar" aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100}>
      <div style={{ width: "100%", height: "100%", background: "var(--accent)", transform: `scaleX(${pct / 100})`, transformOrigin: "left", transition: "transform 240ms ease-out" }} />
    </div>
  );
}

function PathBadge({ path }: { path: PathInfo }) {
  const l = pathLabel(path);
  return (
    <span className="t-small flex items-center gap-1" title={l.detail} data-testid="path" data-kind={path.kind}>
      {path.kind === "local" ? <Wifi size={14} /> : <Check size={14} />} {l.title}
      {path.rttMs !== null ? ` · ${path.rttMs} ms` : ""}
    </span>
  );
}

/** Opened by the Camera app on the sender with a reply: pass it to the tab that asked. */
function Handoff({ answer }: { answer: string }) {
  useEffect(() => channel?.postMessage({ answer }), [answer]);
  return (
    <main className="min-h-dvh grid place-items-center p-8 text-center">
      <div className="flex flex-col gap-3">
        <h1 className="t-h1">Reply received</h1>
        <p className="t-lead">Switch back to the SwiftDrop tab that showed the code.</p>
      </div>
    </main>
  );
}

async function refreshPath(s: PeerSession, set: (p: PathInfo) => void) {
  for (let i = 0; i < 40 && s.pc.connectionState !== "closed"; i++) {
    set(await describePath(s.pc).catch(() => ({ kind: "unknown", local: null, remote: null, rttMs: null }) as PathInfo));
    await new Promise((r) => setTimeout(r, i < 5 ? 600 : 3000));
  }
}

async function enoughSpace(o: IncomingOffer): Promise<boolean> {
  try {
    const e = await navigator.storage.estimate();
    if (e.quota !== undefined && e.usage !== undefined && e.quota - e.usage < o.totalBytes + 50e6) {
      alertSpace(o.totalBytes);
      return false;
    }
  } catch {
    /* no estimate: let writes report it */
  }
  return true;
}

function alertSpace(bytes: number) {
  const el = document.createElement("div");
  el.setAttribute("role", "alert");
  el.className = "t-small";
  el.textContent = `Not enough free space for ${formatBytes(bytes)} on this phone.`;
  document.querySelector("main")?.prepend(el);
}

function download(f: File) {
  const url = URL.createObjectURL(f);
  const a = document.createElement("a");
  a.href = url;
  a.download = f.name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

function useRate(bytes: number): number {
  const hist = useRef<Array<[number, number]>>([]);
  const now = performance.now();
  const h = hist.current;
  if (!h.length || h[h.length - 1]![1] !== bytes) h.push([now, bytes]);
  while (h.length > 2 && now - h[0]![0] > 3000) h.shift();
  if (h.length < 2) return 0;
  const [t0, b0] = h[0]!;
  return now > t0 ? ((bytes - b0) * 1000) / (now - t0) : 0;
}

function useWakeLock(on: boolean) {
  useEffect(() => {
    if (!on || !("wakeLock" in navigator)) return;
    let lock: WakeLockSentinel | null = null;
    void navigator.wakeLock
      .request("screen")
      .then((l) => (lock = l))
      .catch(() => undefined);
    return () => void lock?.release().catch(() => undefined);
  }, [on]);
}
