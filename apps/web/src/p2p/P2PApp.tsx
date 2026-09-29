import { describePath, pathLabel, PEER_CONTROLLER, PeerReceiver, PeerSession, PeerTransport, type IncomingOffer, type PathInfo, type ReceivedTransfer } from "@swiftdrop/peer";
import { formatBytes, formatCount } from "@swiftdrop/shared";
import { TransferJob } from "@swiftdrop/transfer-engine";
import { ArrowDownToLine, ArrowUpFromLine, Download, FileText, Film, FolderUp, ImageIcon, Images, LoaderCircle, RefreshCw, ScanLine, Share, X } from "lucide-react";
import QRCode from "qrcode";
import { memo, useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Connection } from "../components/Connection.tsx";
import { QrCode } from "../components/QrCode.tsx";
import { canShareFiles, deviceLabel, deviceName } from "../lib/env.ts";
import { describe, fromInput, kindOf, toSources, type Picked } from "../lib/files.ts";
import { humanDuration, humanEta } from "../lib/recent.ts";
import { AnimatedNumber } from "../ui/AnimatedNumber.tsx";
import { Logo } from "../ui/Logo.tsx";
import { Swap } from "../ui/Swap.tsx";
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

const here = deviceLabel() === "This device" ? "This device" : `This ${deviceLabel()}`;
const plural = (n: number, one: string, many = `${one}s`) => `${formatCount(n)} ${n === 1 ? one : many}`;

export function P2PApp() {
  const [role, setRole] = useState<"send" | "receive" | null>(initialOffer ? "receive" : null);
  const [stage, setStage] = useState<Stage>({ k: "home" });
  const [picked, setPicked] = useState<Picked[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [path, setPath] = useState<PathInfo | null>(null);
  const [peerName, setPeerName] = useState("");
  const [offer, setOffer] = useState<{ offer: IncomingOffer; decide: (ok: boolean) => void } | null>(null);
  const [dismissed, setDismissed] = useState<Set<string>>(() => new Set());
  const [, setTick] = useState(0);
  const filesInput = useRef<HTMLInputElement>(null);
  const mediaInput = useRef<HTMLInputElement>(null);
  const session = useRef<PeerSession | null>(null);
  const transport = useRef(new PeerTransport());
  const job = useRef<TransferJob | null>(null);
  const offerLink = useRef<string | null>(null);
  const sinks = useMemo(() => (opfsAvailable() ? new OpfsSinkFactory() : null), []);
  const receiver = useMemo(
    () =>
      sinks
        ? new PeerReceiver({
            sinks,
            state: new OpfsStateStore(),
            accept: (o) => new Promise<boolean>((resolve) => setOffer({ offer: o, decide: (ok) => (setOffer(null), resolve(ok ? enoughSpace(o, setError) : Promise.resolve(false))) })),
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

  const fail = useCallback((e: unknown) => setError(plainError(e)), []);

  /** A DataChannel is open: hand it to whichever side this phone plays. */
  const connected = useCallback(
    async (s: PeerSession, as: "send" | "receive") => {
      const link = await s.transport();
      setPeerName(s.remoteName);
      setStage({ k: "transfer" });
      const unfinished = () => {
        const j = job.current;
        const receiving = as === "receive" && receiver?.list().some((t) => t.filesDone < t.files.length);
        return Boolean((j && !["complete", "cancelled", "failed"].includes(j.state)) || receiving);
      };
      link.onClose(() => unfinished() && setStage({ k: "lost" }));
      // The channel only reports "closed" once ICE gives up, which can take half a minute.
      // Show the interruption as soon as the connection drops, and take it back if it recovers.
      s.pc.addEventListener("connectionstatechange", () => {
        if (session.current !== s) return;
        const st = s.pc.connectionState;
        if ((st === "disconnected" || st === "failed") && unfinished()) setStage({ k: "lost" });
        else if (st === "connected") setStage((cur) => (cur.k === "lost" ? { k: "transfer" } : cur));
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
    setBusy(true);
    try {
      session.current?.close();
      setPath(null);
      const { session: s, offer } = await PeerSession.offer({ name, framing });
      session.current = s;
      offerLink.current = `${location.origin}${location.pathname}#o=${offer}`;
      setStage({ k: "send-offer", link: offerLink.current });
    } catch (e) {
      fail(e);
    } finally {
      setBusy(false);
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
        setPath(null);
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

  /** Back to the start, ready for another transfer. Received files stay in storage until saved. */
  const reset = useCallback(
    (doneWith?: string) => {
      job.current = null;
      transport.current = new PeerTransport();
      session.current?.close();
      session.current = null;
      if (doneWith) setDismissed((d) => new Set(d).add(doneWith));
      setPath(null);
      setPicked([]);
      setPeerName("");
      setError(null);
      setRole(null);
      setStage({ k: "home" });
    },
    [],
  );

  if (initialAnswer) return <Handoff answer={initialAnswer} />;

  const j = job.current;
  const incoming = receiver?.list().filter((t) => !dismissed.has(t.id)).sort((a, b) => b.createdAt - a.createdAt)[0] ?? null;
  const peer = peerName || "the other phone";
  const addPicked = (p: Picked[]) => setPicked((cur) => dedupe([...cur, ...p]));

  // One screen at a time; the dock holds its actions within thumb reach.
  let screen: { key: string; body: ReactNode; dock?: ReactNode };
  if (offer) {
    screen = {
      key: "accept",
      body: <AcceptCard offer={offer.offer} from={peer} />,
      dock: (
        <div className="p2p-dock-2">
          <button className="btn btn-secondary btn-lg" onClick={() => offer.decide(false)}>
            Decline
          </button>
          <button className="btn btn-primary btn-lg" onClick={() => offer.decide(true)}>
            Accept
          </button>
        </div>
      ),
    };
  } else if (stage.k === "lost" || (stage.k === "transfer" && role === "send" && j?.state === "reconnecting")) {
    const pct = role === "send" ? (j ? pctOf(j.snapshot().bytesDone, j.snapshot().bytesTotal) : 0) : incoming ? pctOf(incoming.bytesDone, incoming.bytesTotal) : 0;
    screen = {
      key: "lost",
      body: <Interrupted pct={pct} role={role} peer={peer} />,
      dock:
        role === "send" ? (
          <button className="btn btn-primary btn-lg w-full" disabled={busy} onClick={() => void makeOffer()}>
            {busy ? <LoaderCircle size={20} className="p2p-spin" /> : <RefreshCw size={20} strokeWidth={1.75} />} Continue
          </button>
        ) : (
          <button className="btn btn-primary btn-lg w-full" onClick={() => setStage({ k: "recv-scan" })}>
            <ScanLine size={20} strokeWidth={1.75} /> Continue
          </button>
        ),
    };
  } else if (stage.k === "transfer" && role === "send" && j) {
    const done = j.state === "complete";
    screen = { key: "send", body: <SendView job={j} peer={peer} />, dock: done ? <DoneButton onClick={() => reset()} /> : undefined };
  } else if (stage.k === "transfer" && role === "receive" && incoming) {
    const done = incoming.filesDone === incoming.files.length;
    screen = { key: "receive", body: <ReceiveView t={incoming} receiver={receiver!} peer={peer} />, dock: done ? <DoneButton onClick={() => reset(incoming.id)} /> : undefined };
  } else if (stage.k === "transfer" || stage.k === "connecting") {
    screen = { key: stage.k === "transfer" ? "linked" : "connecting", body: <Linking linked={stage.k === "transfer"} role={role} peer={peer} /> };
  } else if (stage.k === "send-offer") {
    screen = {
      key: "send-offer",
      body: (
        <Pairing step={1} role="send" title="Scan this code with the other phone" hint="Use its Camera app, or tap Receive in SwiftDrop there.">
          <SignalCode link={stage.link} label="Pairing code for the other phone" />
        </Pairing>
      ),
      dock: (
        <button className="btn btn-primary btn-lg w-full" onClick={() => setStage({ k: "send-scan" })}>
          <ScanLine size={20} strokeWidth={1.75} /> Scan its reply
        </button>
      ),
    };
  } else if (stage.k === "send-scan") {
    screen = {
      key: "send-scan",
      body: (
        <Pairing step={2} role="send" title="Scan the code on the other phone" hint="It shows a reply code once it has scanned yours.">
          <Scanner hint="Hold this phone over the other phone's screen." onResult={(t) => void takeAnswer(t)} />
        </Pairing>
      ),
      dock: offerLink.current ? (
        <button className="btn btn-ghost btn-lg w-full" onClick={() => setStage({ k: "send-offer", link: offerLink.current! })}>
          Show my code again
        </button>
      ) : undefined,
    };
  } else if (stage.k === "recv-scan") {
    screen = {
      key: "recv-scan",
      body: (
        <Pairing step={1} role="receive" title="Scan the sender's code" hint="On the other phone: tap Send, choose files, then Show code.">
          <Scanner hint="Point this phone at the code on the sender's screen." onResult={(t) => void takeOffer(t)} />
        </Pairing>
      ),
      dock: <BackButton onClick={() => reset()} />,
    };
  } else if (stage.k === "recv-answer") {
    screen = {
      key: "recv-answer",
      body: (
        <Pairing step={2} role="receive" title={`Now let ${peerName || "the sender"} scan this`} hint="On the sender, tap Scan its reply and point it here. The phones connect on their own.">
          <SignalCode link={stage.link} label="Reply code for the sender" />
        </Pairing>
      ),
    };
  } else if (role === "send") {
    screen = {
      key: "choose",
      body: (
        <Choose
          picked={picked}
          onMedia={() => mediaInput.current?.click()}
          onFiles={() => filesInput.current?.click()}
          onRemove={(i) => setPicked((cur) => cur.filter((_, k) => k !== i))}
          onClear={() => setPicked([])}
        />
      ),
      dock: picked.length ? (
        <button className="btn btn-primary btn-lg w-full" disabled={busy} onClick={() => void makeOffer()}>
          {busy && <LoaderCircle size={20} className="p2p-spin" />}
          Show code to the other phone
        </button>
      ) : (
        <BackButton onClick={() => reset()} />
      ),
    };
  } else {
    screen = {
      key: "home",
      body: <Home canReceive={Boolean(receiver)} />,
      dock: (
        <div className="p2p-dock-2">
          <button className="btn btn-primary btn-lg" onClick={() => (setRole("send"), filesInput.current?.click())}>
            <ArrowUpFromLine size={20} strokeWidth={1.75} /> Send
          </button>
          <button className="btn btn-secondary btn-lg" disabled={!receiver} onClick={() => (setRole("receive"), setStage({ k: "recv-scan" }))}>
            <ArrowDownToLine size={20} strokeWidth={1.75} /> Receive
          </button>
        </div>
      ),
    };
  }

  const status = linkStatus(stage.k, path);

  return (
    <div className="p2p">
      <header className="topbar">
        <span className="wordmark">
          <Logo size={24} />
          SwiftDrop
        </span>
        <span className="pill p2p-status" role="status" aria-label={`Connection: ${status.text}`} {...(path && stage.k === "transfer" ? { "data-testid": "path", "data-kind": path.kind, title: pathLabel(path).detail } : {})}>
          <span className="dot" data-state={status.dot} />
          {status.text}
        </span>
      </header>

      <main className="p2p-main" aria-live="polite">
        {!isSecureContext && (
          <p className="p2p-alert" role="alert">
            Open this page over https to send phone to phone. The camera and file storage need a secure page.
          </p>
        )}
        {error && (
          <div className="p2p-alert" role="alert">
            <span>{error}</span>
            <button className="btn btn-ghost btn-sm btn-icon" aria-label="Dismiss" onClick={() => setError(null)}>
              <X size={16} strokeWidth={1.75} />
            </button>
          </div>
        )}
        <Swap k={screen.key}>{screen.body}</Swap>
      </main>

      {screen.dock && <div className="dock p2p-dock">{screen.dock}</div>}

      <input
        ref={filesInput}
        type="file"
        multiple
        hidden
        onChange={(e) => {
          const p = fromInput(e.target.files);
          e.target.value = "";
          if (p.length) addPicked(p);
        }}
      />
      <input
        ref={mediaInput}
        type="file"
        accept="image/*,video/*"
        multiple
        hidden
        onChange={(e) => {
          const p = fromInput(e.target.files);
          e.target.value = "";
          if (p.length) addPicked(p);
        }}
      />
    </div>
  );
}

// ---- screens -------------------------------------------------------------------

function Home({ canReceive }: { canReceive: boolean }) {
  return (
    <div className="flex flex-col gap-10">
      <div className="flex flex-col gap-4 rise">
        <h1 className="t-display p2p-title">Phone to phone</h1>
        <p className="t-lead">Send photos, videos and files straight to another phone. No PC, no cloud, no account.</p>
      </div>
      <div className="rise" style={{ "--i": 1 } as React.CSSProperties}>
        <Connection state="waiting" left={{ name: here, kind: "phone", live: true }} right={{ name: "Other phone", kind: "phone", live: false }} />
      </div>
      <ol className="p2p-how rise" style={{ "--i": 2 } as React.CSSProperties}>
        <li>
          <span className="pair-step-n num">1</span>
          <span>
            <span className="pair-step-t">Open this page on both phones</span>
            <span className="t-small">Same Wi-Fi, or one phone's hotspot.</span>
          </span>
        </li>
        <li>
          <span className="pair-step-n num">2</span>
          <span>
            <span className="pair-step-t">Each scans the other's code once</span>
            <span className="t-small">The codes carry connection details, never your files.</span>
          </span>
        </li>
        <li>
          <span className="pair-step-n num">3</span>
          <span>
            <span className="pair-step-t">Files go directly between the phones</span>
            <span className="t-small">Every block is checked when it arrives.</span>
          </span>
        </li>
      </ol>
      {!canReceive && <p className="t-small">This browser can't store received files here, so it can only send. Receiving needs Safari or Chrome over https.</p>}
    </div>
  );
}

function Choose({ picked, onMedia, onFiles, onRemove, onClear }: { picked: Picked[]; onMedia: () => void; onFiles: () => void; onRemove: (i: number) => void; onClear: () => void }) {
  const total = picked.reduce((s, p) => s + p.file.size, 0);
  return (
    <div className="flex flex-col gap-8">
      <div className="flex flex-col gap-2">
        <p className="t-section">Send</p>
        <h1 className="t-h1 num">{picked.length ? plural(picked.length, "item") : "Choose what to send"}</h1>
        <p className="t-lead num">{picked.length ? `${formatBytes(total)} · ${describe(picked)}` : "Pick from your library or your files. You can add more before you pair."}</p>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <button className="p2p-choice" onClick={onMedia}>
          <Images size={22} strokeWidth={1.5} />
          <span>{picked.length ? "Add photos & videos" : "Photos & videos"}</span>
        </button>
        <button className="p2p-choice" onClick={onFiles}>
          <FolderUp size={22} strokeWidth={1.5} />
          <span>{picked.length ? "Add files" : "Files"}</span>
        </button>
      </div>
      {picked.length > 0 && (
        <section className="flex flex-col gap-3" aria-label="Selected items">
          <PickedGrid picked={picked} onRemove={onRemove} />
          <button className="btn btn-ghost btn-sm self-start -ml-3" onClick={onClear}>
            Clear selection
          </button>
        </section>
      )}
    </div>
  );
}

const GRID_MAX = 11;

function PickedGrid({ picked, onRemove }: { picked: Picked[]; onRemove: (i: number) => void }) {
  const shown = picked.slice(0, GRID_MAX);
  return (
    <ul className="p2p-grid">
      {shown.map((p, i) => (
        <li key={`${p.relDir}/${p.file.name}/${p.file.size}/${p.file.lastModified}`} className="thumb">
          <Tile file={p.file} />
          <button className="p2p-remove" aria-label={`Remove ${p.file.name}`} onClick={() => onRemove(i)}>
            <X size={13} strokeWidth={2.25} />
          </button>
        </li>
      ))}
      {picked.length > GRID_MAX && (
        <li className="thumb p2p-more num" aria-label={`${formatCount(picked.length - GRID_MAX)} more`}>
          +{formatCount(picked.length - GRID_MAX)}
        </li>
      )}
    </ul>
  );
}

const Tile = memo(function Tile({ file }: { file: File }) {
  const kind = kindOf(file.name, file.type);
  const [url, setUrl] = useState<string | null>(null);
  const [broken, setBroken] = useState(false);
  useEffect(() => {
    if (kind !== "image" || file.size > 30e6) return;
    const u = URL.createObjectURL(file);
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [file, kind]);
  if (url && !broken) return <img src={url} alt="" decoding="async" onError={() => setBroken(true)} />;
  const Icon = kind === "video" ? Film : kind === "image" ? ImageIcon : FileText;
  return (
    <span className="p2p-tile-icon">
      <Icon size={18} strokeWidth={1.5} />
      <span className="t-micro truncate">{file.name}</span>
    </span>
  );
});

function Pairing({ step, role, title, hint, children }: { step: 1 | 2; role: "send" | "receive"; title: string; hint: string; children: ReactNode }) {
  const steps = role === "send" ? ["Show code", "Scan reply", "Send"] : ["Scan code", "Show reply", "Receive"];
  return (
    <div className="flex flex-col gap-6">
      <ol className="p2p-steps" aria-label={`Pairing, step ${step} of 3`}>
        {steps.map((s, i) => (
          <li key={s} data-state={i + 1 < step ? "done" : i + 1 === step ? "current" : "todo"} aria-current={i + 1 === step ? "step" : undefined}>
            <span className="num">{i + 1}</span>
            {s}
          </li>
        ))}
      </ol>
      <div className="flex flex-col gap-2">
        <h1 className="t-h1">{title}</h1>
        <p className="t-body">{hint}</p>
      </div>
      {children}
    </div>
  );
}

function SignalCode({ link, label }: { link: string; label: string }) {
  const qr = useMemo(() => {
    const m = QRCode.create(link, { errorCorrectionLevel: "L" }).modules;
    let s = "";
    for (let i = 0; i < m.data.length; i++) s += String.fromCharCode(m.data[i]!);
    return { size: m.size, bits: btoa(s) };
  }, [link]);
  return (
    <div className="flex flex-col items-center gap-4">
      <div data-testid="signal" data-signal={link} className="qr-object p2p-qr">
        <QrCode size={qr.size} bits={qr.bits} label={label} />
      </div>
      <p className="t-small text-center">Turn this screen's brightness up if the other phone can't read it.</p>
    </div>
  );
}

function Linking({ linked, role, peer }: { linked: boolean; role: "send" | "receive" | null; peer: string }) {
  return (
    <div className="flex flex-col gap-10 pt-6">
      <Connection
        state={linked ? "connected" : "connecting"}
        left={{ name: here, kind: "phone", live: true }}
        right={{ name: linked ? cap(peer) : "Other phone", kind: "phone", live: linked }}
        flow={role === "receive" ? "left" : "right"}
      />
      <div className="flex flex-col gap-2 text-center items-center">
        <h1 className="t-h1">{linked ? "Connected" : "Connecting…"}</h1>
        <p className="t-body">{linked ? (role === "receive" ? `Waiting for ${peer} to send.` : "Starting the transfer.") : "Setting up a direct link between the two phones."}</p>
      </div>
    </div>
  );
}

function AcceptCard({ offer, from }: { offer: IncomingOffer; from: string }) {
  const media = offer.files.filter((f) => ["image", "video"].includes(kindOf(f.name, f.type))).length;
  return (
    <div className="flex flex-col gap-8" role="dialog" aria-label="Incoming files" aria-describedby="incoming-summary">
      <Connection state="connected" left={{ name: here, kind: "phone", live: true }} right={{ name: cap(from), kind: "phone", live: true }} flow="left" target="left" compact />
      <div className="flex flex-col gap-2">
        <p className="t-section">Incoming transfer</p>
        <h1 className="t-h1">
          {cap(from)} wants to send {plural(offer.files.length, "file")}
        </h1>
        <p id="incoming-summary" className="p2p-figure num">
          {formatBytes(offer.totalBytes)}
          {media > 0 && media < offer.files.length && <span className="t-small"> · {plural(media, "photo or video", "photos and videos")}</span>}
        </p>
      </div>
      <ul className="surface p2p-list">
        {offer.files.slice(0, 50).map((f) => (
          <li key={f.id}>
            <FileGlyph name={f.name} type={f.type} />
            <span className="truncate min-w-0">
              {f.relDir ? <span style={{ color: "var(--text-4)" }}>{f.relDir}/</span> : null}
              {f.name}
            </span>
            <span className="t-small num">{formatBytes(f.size)}</span>
          </li>
        ))}
        {offer.files.length > 50 && <li className="t-small">…and {formatCount(offer.files.length - 50)} more</li>}
      </ul>
    </div>
  );
}

function SendView({ job, peer }: { job: TransferJob; peer: string }) {
  const s = job.snapshot();
  if (s.state === "complete") {
    return (
      <div data-testid="send-progress" data-state={s.state}>
        <Complete sent files={s.filesTotal} bytes={s.bytesTotal} peer={peer} seconds={s.elapsedSeconds} />
      </div>
    );
  }
  const waiting = s.state === "preparing" || s.state === "queued";
  return (
    <div data-testid="send-progress" data-state={s.state}>
      <Progress
        verb={waiting ? `Waiting for ${peer} to accept` : s.state === "reconnecting" ? "Reconnecting" : s.state === "failed" ? "Stopped" : `Sending to ${peer}`}
        live={s.state === "running"}
        label={job.label}
        filesDone={s.filesDone}
        filesTotal={s.filesTotal}
        bytesDone={s.bytesDone}
        bytesTotal={s.bytesTotal}
        speed={s.speed}
        eta={waiting ? null : s.etaSeconds}
        flow="right"
        peer={peer}
        message={s.state === "failed" ? plainError(s.message ?? "The transfer stopped.") : null}
      />
    </div>
  );
}

function ReceiveView({ t, receiver, peer }: { t: ReceivedTransfer; receiver: PeerReceiver; peer: string }) {
  const done = t.filesDone === t.files.length;
  const speed = useRate(t.bytesDone);
  const secs = elapsed(t.id, done);
  return (
    <div data-testid="receive-progress" data-state={done ? "complete" : "active"}>
      {done ? (
        <Complete sent={false} files={t.files.length} bytes={t.bytesTotal} peer={peer} seconds={secs}>
          <Saved t={t} receiver={receiver} />
        </Complete>
      ) : (
        <Progress
          verb={`Receiving from ${peer}`}
          live={speed > 0}
          label={t.label}
          filesDone={t.filesDone}
          filesTotal={t.files.length}
          bytesDone={t.bytesDone}
          bytesTotal={t.bytesTotal}
          speed={speed}
          eta={speed > 0 ? (t.bytesTotal - t.bytesDone) / speed : Infinity}
          flow="left"
          peer={peer}
          message={null}
        />
      )}
    </div>
  );
}

const fmtPct = (v: number) => String(Math.min(100, Math.max(0, Math.floor(v))));
const fmtRate = (v: number) => (v >= 100 ? v.toFixed(0) : v.toFixed(1));

function Progress(p: {
  verb: string;
  live: boolean;
  label: string;
  filesDone: number;
  filesTotal: number;
  bytesDone: number;
  bytesTotal: number;
  speed: number;
  eta: number | null;
  flow: "left" | "right";
  peer: string;
  message: string | null;
}) {
  const pct = pctOf(p.bytesDone, p.bytesTotal);
  return (
    <section className="flex flex-col gap-8" aria-label="Transfer in progress">
      <Connection
        state={p.live ? "transferring" : "connected"}
        left={{ name: here, kind: "phone", live: true }}
        right={{ name: cap(p.peer), kind: "phone", live: true }}
        flow={p.flow}
        speed={p.speed}
        target={p.flow === "right" ? "right" : "left"}
        compact
      />
      <header className="flex flex-col gap-1 min-w-0">
        <div className="t-small flex items-center gap-2" style={{ color: "var(--text-2)" }}>
          <span className="dot" data-state={p.live ? "live" : p.message ? "warn" : undefined} />
          {p.verb}
        </div>
        <h1 className="t-h2 truncate">{p.label}</h1>
      </header>

      <div className="flex items-end justify-between gap-6">
        <div className="num leading-none" style={{ fontSize: "var(--t-hero-num)", fontWeight: 480, letterSpacing: "-0.05em" }}>
          <AnimatedNumber value={pct} format={fmtPct} />
          <span style={{ fontSize: "0.4em", color: "var(--text-3)", marginLeft: "0.08em", letterSpacing: "-0.02em" }}>%</span>
        </div>
        <div className="text-right">
          <div className="num leading-none" style={{ fontSize: "clamp(1.75rem, 1.4rem + 1.6vw, 2.5rem)", fontWeight: 500, letterSpacing: "-0.035em" }}>
            <AnimatedNumber value={p.speed / 1e6} format={fmtRate} />
            <span style={{ fontSize: "0.5em", color: "var(--text-3)", marginLeft: 5, letterSpacing: "-0.01em" }}>MB/s</span>
          </div>
          <div className="t-small mt-2">speed</div>
        </div>
      </div>

      <div className="flex flex-col gap-3">
        <div
          className="bar"
          role="progressbar"
          aria-label="Transfer progress"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={Math.floor(pct)}
          aria-valuetext={`${Math.floor(pct)}%, ${formatCount(p.filesDone)} of ${plural(p.filesTotal, "file")}`}
        >
          <span style={{ "--p": pct / 100 } as React.CSSProperties} />
        </div>
        <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-1">
          <span className="t-small num" style={{ color: "var(--text-2)" }}>
            {p.eta === null ? "Starts when they accept" : humanEta(p.eta)}
          </span>
          <span className="t-small num">
            {formatCount(p.filesDone)} of {plural(p.filesTotal, "file")} · {formatBytes(p.bytesDone)} of {formatBytes(p.bytesTotal)}
          </span>
        </div>
      </div>

      {p.message && (
        <p className="p2p-alert" role="alert">
          {p.message}
        </p>
      )}
      <p className="t-small">Keep both screens on until it finishes.</p>
    </section>
  );
}

function Complete({ sent, files, bytes, peer, seconds, children }: { sent: boolean; files: number; bytes: number; peer: string; seconds: number; children?: ReactNode }) {
  return (
    <section className="flex flex-col gap-8" aria-label="Transfer complete">
      <div className="flex flex-col items-center text-center gap-5 pt-4">
        <VerifiedMark />
        <div className="flex flex-col gap-2 items-center">
          <h1 className="t-h1">Transfer complete</h1>
          <p className="t-lead num">
            {plural(files, "file")} · {formatBytes(bytes)}
          </p>
          <p className="t-small num">
            {sent ? `Sent to ${peer}` : `Received from ${peer}`}
            {seconds > 0 ? ` in ${humanDuration(seconds)}` : ""}
          </p>
        </div>
        <span className="pill p2p-verified">
          <svg viewBox="0 0 100 100" width="14" height="14" aria-hidden>
            <path d="M16 56 L40 80 L86 20" />
          </svg>
          Verified · every block checked
        </span>
      </div>
      {children}
    </section>
  );
}

/** The grease-pencil tick from the website, drawn once as an app check. */
function VerifiedMark() {
  return (
    <div className="p2p-mark" aria-hidden>
      <svg viewBox="0 0 100 100" width="36" height="36">
        <path pathLength={1} d="M16 56 L40 80 L86 20" />
      </svg>
    </div>
  );
}

function Saved({ t, receiver }: { t: ReceivedTransfer; receiver: PeerReceiver }) {
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
    <div className="flex flex-col gap-4">
      <button className="btn btn-primary btn-lg w-full" disabled={saving} onClick={() => void saveAll()}>
        {saving ? <LoaderCircle size={20} className="p2p-spin" /> : <Share size={20} strokeWidth={1.75} />} {t.files.length === 1 ? "Save" : "Save all"}
      </button>
      <ul className="surface p2p-list">
        {t.files.map((f) => (
          <li key={f.id}>
            <FileGlyph name={f.name} type={f.type} />
            <span className="truncate min-w-0">{[...f.relDir, f.name].join("/")}</span>
            <button className="btn btn-ghost btn-sm btn-icon" aria-label={`Save ${f.name}`} onClick={() => void receiver.file(t, f).then(download)}>
              <Download size={16} strokeWidth={1.75} />
            </button>
          </li>
        ))}
      </ul>
      <p className="t-small">Received files stay in this browser until you save them to Photos or Files.</p>
    </div>
  );
}

function Interrupted({ pct, role, peer }: { pct: number; role: "send" | "receive" | null; peer: string }) {
  return (
    <section className="flex flex-col gap-8 pt-6" aria-label="Connection interrupted">
      <Connection state="waiting" left={{ name: here, kind: "phone", live: true }} right={{ name: cap(peer), kind: "phone", live: false }} compact />
      <div className="flex flex-col gap-3">
        <div className="bar" data-tone="paused" role="progressbar" aria-label="Transfer progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.floor(pct)}>
          <span style={{ "--p": pct / 100 } as React.CSSProperties} />
        </div>
        <span className="t-small num">Stopped at {Math.floor(pct)}%</span>
      </div>
      <div className="flex flex-col gap-3">
        <h1 className="t-h1">Connection interrupted</h1>
        <p className="t-lead">Your transfer is safe. Nothing that already arrived will be sent again.</p>
        <p className="t-body flex items-center gap-2">
          <LoaderCircle size={16} strokeWidth={1.75} className="p2p-spin flex-none" aria-hidden /> Waiting for the phones to reconnect…
        </p>
        <p className="t-small">
          {role === "send"
            ? `If it doesn't come back, tap Continue to show a new code and let ${peer} scan it. It picks up from ${Math.floor(pct)}%.`
            : `If it doesn't come back, tap Continue and scan the new code on ${peer}. It picks up from ${Math.floor(pct)}%.`}
        </p>
      </div>
    </section>
  );
}

function DoneButton({ onClick }: { onClick: () => void }) {
  return (
    <button className="btn btn-secondary btn-lg w-full" onClick={onClick}>
      Done
    </button>
  );
}

function BackButton({ onClick }: { onClick: () => void }) {
  return (
    <button className="btn btn-ghost btn-lg w-full" onClick={onClick}>
      Cancel
    </button>
  );
}

function FileGlyph({ name, type }: { name: string; type: string }) {
  const k = kindOf(name, type);
  const Icon = k === "video" ? Film : k === "image" ? ImageIcon : FileText;
  return (
    <span className="p2p-glyph" aria-hidden>
      <Icon size={16} strokeWidth={1.5} />
    </span>
  );
}

/** Opened by the Camera app on the sender with a reply: pass it to the tab that asked. */
function Handoff({ answer }: { answer: string }) {
  useEffect(() => channel?.postMessage({ answer }), [answer]);
  return (
    <main className="min-h-dvh grid place-items-center p-8 text-center">
      <div className="flex flex-col items-center gap-4">
        <Logo size={40} />
        <h1 className="t-h1">Reply received</h1>
        <p className="t-lead">Switch back to the SwiftDrop tab that showed the code. The phones connect from there.</p>
      </div>
    </main>
  );
}

// ---- helpers -------------------------------------------------------------------

function linkStatus(k: Stage["k"], path: PathInfo | null): { text: string; dot?: "live" | "warn" } {
  if (k === "transfer") return { text: path ? pathLabel(path).title : "Connected", dot: "live" };
  if (k === "connecting") return { text: "Connecting…" };
  if (k === "lost") return { text: "Interrupted", dot: "warn" };
  if (k === "send-offer" || k === "send-scan" || k === "recv-scan" || k === "recv-answer") return { text: "Pairing" };
  return { text: "Not connected" };
}

/** When each received transfer was first shown and when it finished; survives the screen swap remount. */
const timings = new Map<string, { start: number; end: number | null }>();
function elapsed(id: string, done: boolean): number {
  let t = timings.get(id);
  if (!t) timings.set(id, (t = { start: performance.now(), end: null }));
  if (done && t.end === null) t.end = performance.now();
  return t.end === null ? 0 : (t.end - t.start) / 1000;
}

const pctOf = (done: number, total: number) => (total > 0 ? (done / total) * 100 : 100);
/** Sentence-start form of a peer name: only the generic fallback needs it ("iPhone" stays as is). */
const cap = (s: string) => (s.startsWith("the ") ? `T${s.slice(1)}` : s);

function dedupe(list: Picked[]): Picked[] {
  const seen = new Set<string>();
  return list.filter((p) => {
    const k = `${p.relDir}/${p.file.name}/${p.file.size}/${p.file.lastModified}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}

/** Engine and WebRTC errors in words a person can act on. */
function plainError(e: unknown): string {
  const m = e instanceof Error ? e.message : String(e);
  if (/channel closed|closed|no local description|ICE|SDP|RTC/i.test(m)) return "The connection closed before it finished setting up. Try pairing again.";
  return m;
}

async function refreshPath(s: PeerSession, set: (p: PathInfo) => void) {
  for (let i = 0; i < 40 && s.pc.connectionState !== "closed"; i++) {
    set(await describePath(s.pc).catch(() => ({ kind: "unknown", local: null, remote: null, rttMs: null }) as PathInfo));
    await new Promise((r) => setTimeout(r, i < 5 ? 600 : 3000));
  }
}

async function enoughSpace(o: IncomingOffer, report: (m: string) => void): Promise<boolean> {
  try {
    const e = await navigator.storage.estimate();
    if (e.quota !== undefined && e.usage !== undefined && e.quota - e.usage < o.totalBytes + 50e6) {
      report(`Not enough free space for ${formatBytes(o.totalBytes)} on this phone.`);
      return false;
    }
  } catch {
    /* no estimate: let writes report it */
  }
  return true;
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

