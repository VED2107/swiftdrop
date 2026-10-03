import { describePath, pathLabel, PEER_CONTROLLER, PeerReceiver, PeerTransport, type DataChannelTransport, type IncomingOffer, type PathInfo, type PeerSession, type ReceivedTransfer } from "@swiftdrop/peer";
import { formatBytes, formatCount } from "@swiftdrop/shared";
import { TransferJob } from "@swiftdrop/transfer-engine";
import { ArrowDown, ArrowUp, Check, Download, Files, FileText, Film, ImageIcon, LoaderCircle, Monitor, Plus, RefreshCw, ScanLine, Send, Share, Smartphone, X } from "lucide-react";
import QRCode from "qrcode";
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Connection } from "../components/Connection.tsx";
import { QrCode } from "../components/QrCode.tsx";
import { canShareFiles, deviceLabel, deviceName, isMobile } from "../lib/env.ts";
import { describe, fromDataTransfer, fromInput, kindOf, toSources, type Picked } from "../lib/files.ts";
import { humanDuration, humanEta, timeAgo } from "../lib/recent.ts";
import { AnimatedNumber } from "../ui/AnimatedNumber.tsx";
import { Swap } from "../ui/Swap.tsx";
import { DebugPanel, type DebugSources } from "./Debug.tsx";
import { addHistory, useHistory, type HistoryItem } from "./history.ts";
import { OpfsSinkFactory, OpfsStateStore, opfsAvailable } from "./opfs.ts";
import { GuestPairing, HostPairing, type Linked } from "./pairing.ts";
import { Scanner } from "./Scanner.tsx";

/**
 * Phone ↔ phone, direct. The sender picks files and shows one QR; the receiver scans it.
 * The QR and the rendezvous mailbox carry connection details only (SDP); every file byte
 * goes over a WebRTC DataChannel between the two devices, never through a server.
 *
 * The connection is warm before anything moves: the offer's ICE gathering runs while the
 * file picker is open, and a receiver's Accept starts the first 1 MiB request at once.
 */

/** What the person is looking at. Every screen maps to exactly one. */
type Phase = "home" | "host" | "host-scan" | "scan" | "reply" | "connecting" | "linked" | "lost";

/** The state machine's public names (spec vocabulary), on the root as data-state. */
type FlowState =
  | "IDLE"
  | "SELECTING"
  | "WAITING_FOR_RECEIVER"
  | "SCANNING"
  | "CONNECTING"
  | "CONNECTED"
  | "AWAITING_ACCEPT"
  | "PREPARING_FIRST_FILE"
  | "TRANSFERRING"
  | "VERIFYING"
  | "COMPLETED"
  | "PAUSED"
  | "RECONNECTING"
  | "FAILED";

const knobs = new URLSearchParams(location.search);
/** Benchmark knobs (`?hw=<KiB>&frame=<KiB>`): send-buffer high-water mark and message size. */
const framing = {
  ...(knobs.get("hw") ? { highWaterMark: Number(knobs.get("hw")) * 1024, lowWaterMark: (Number(knobs.get("hw")) * 1024) / 4 } : {}),
  ...(knobs.get("frame") ? { maxMessageSize: Number(knobs.get("frame")) * 1024 } : {}),
};
const SIGNAL = ((import.meta.env.VITE_SIGNAL_URL as string | undefined) || "https://ntfy.sh").trim();
/** Rendezvous for the one-QR flow; "off" pairs with a reply QR instead (no internet needed). */
const signalUrl = SIGNAL === "off" || knobs.get("signal") === "off" ? null : SIGNAL;
const debug = knobs.has("debug");

const channel = typeof BroadcastChannel === "undefined" ? null : new BroadcastChannel("swiftdrop-p2p");
/** Opened by the Camera app from a sender's QR: this tab is the receiver. */
const initialCode = /[#&]o=[DP][A-Za-z0-9_-]+/.test(location.hash) ? location.href : null;
/** Opened by the Camera app from a receiver's reply QR (offline pairing). */
const initialReply = /[#&]a=([DP][A-Za-z0-9_-]+)/.exec(location.hash)?.[1] ?? null;
if (initialCode || initialReply) history.replaceState(null, "", location.pathname + location.search);

const selfKind: "phone" | "pc" = isMobile ? "phone" : "pc";
const thisDevice = deviceLabel() === "This device" ? "This device" : `This ${deviceLabel()}`;
const plural = (n: number, one: string, many = `${one}s`) => `${formatCount(n)} ${n === 1 ? one : many}`;

export function P2PApp() {
  const [role, setRole] = useState<"send" | "receive" | null>(initialCode ? "receive" : null);
  const [phase, setPhase] = useState<Phase>(initialCode ? "connecting" : "home");
  const [hostLink, setHostLink] = useState<string | null>(null);
  const [replyLink, setReplyLink] = useState<string | null>(null);
  const [picked, setPicked] = useState<Picked[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [path, setPath] = useState<PathInfo | null>(null);
  const [peerName, setPeerName] = useState("");
  const [offer, setOffer] = useState<{ offer: IncomingOffer; decide: (ok: boolean) => void } | null>(null);
  const [dismissed, setDismissed] = useState<Set<string>>(() => new Set());
  const [dragging, setDragging] = useState(false);
  /** null until the rendezvous answers or fails; false shows the reply-QR fallback. */
  const [mailboxOnline, setMailboxOnline] = useState<boolean | null>(null);
  const [, setTick] = useState(0);

  const input = useRef<HTMLInputElement>(null);
  const pickedRef = useRef<Picked[]>([]);
  const roleRef = useRef(role);
  roleRef.current = role;
  const host = useRef<HostPairing | null>(null);
  const guest = useRef<GuestPairing | null>(null);
  const session = useRef<PeerSession | null>(null);
  const link = useRef<DataChannelTransport | null>(null);
  const transport = useRef(new PeerTransport());
  const job = useRef<TransferJob | null>(null);
  const redialTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const endSession = useRef<(message?: string) => void>(() => undefined);
  /** Put away finished incoming transfers (their files stay saved in storage). */
  const clearReceived = useRef<() => void>(() => undefined);
  /** Wall-clock marks for the debug panel: picker returned, link up, job started. */
  const marks = useRef<{ picked: number; linked: number; jobStart: number }>({ picked: 0, linked: 0, jobStart: 0 });

  const name = useMemo(() => deviceName(), []);
  const sinks = useMemo(() => (opfsAvailable() ? new OpfsSinkFactory() : null), []);
  const receiver = useMemo(
    () =>
      sinks
        ? new PeerReceiver({
            sinks,
            state: new OpfsStateStore(),
            accept: (o) =>
              new Promise<boolean>((resolve) =>
                setOffer({
                  offer: o,
                  decide: (ok) => {
                    setOffer(null);
                    // A new incoming transfer replaces this phone's own finished send on screen.
                    if (ok && job.current?.state === "complete") job.current = null;
                    clearReceived.current();
                    resolve(ok ? enoughSpace(o, setError) : Promise.resolve(false));
                  },
                }),
              ),
            onComplete: (t) => addHistory(historyOf(t, "received", session.current?.remoteName || "Other phone", elapsed(t.id, true))),
          })
        : null,
    [sinks],
  );

  // Repaint on a clock (5 Hz): smooth enough to read, nothing renders per chunk.
  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), 200);
    return () => clearInterval(t);
  }, []);

  const fail = useCallback((e: unknown) => setError(plainError(e)), []);

  /** Either direction still moving: once connected, both phones can send. */
  const unfinished = useCallback(() => {
    const j = job.current;
    const sending = Boolean(j && !["complete", "cancelled", "failed"].includes(j.state));
    return sending || Boolean(receiver?.list().some((t) => t.filesDone < t.files.length));
  }, [receiver]);

  const startJob = useCallback(() => {
    const files = pickedRef.current;
    if (!files.length) return;
    const j = new TransferJob({ transport: transport.current, files: toSources(files), direction: "to-peer", label: labelFor(files), controller: PEER_CONTROLLER });
    job.current = j;
    marks.current.jobStart = performance.now();
    j.onChange((x) => {
      if (x.state === "complete") {
        const s = x.snapshot();
        addHistory({ id: x.id, label: x.label, dir: "sent", peer: session.current?.remoteName || "Other phone", files: s.filesTotal, bytes: s.bytesTotal, seconds: s.elapsedSeconds, at: Date.now(), kind: kindSummary(files.map((p) => kindOf(p.file.name, p.file.type))) });
      }
    });
    void j.start();
  }, []);

  /** A DataChannel is open (first pairing or a re-dial): hand it to this phone's side. */
  const onLinked = useCallback(
    ({ session: s, link: l }: Linked) => {
      session.current = s;
      link.current = l;
      marks.current.linked = performance.now();
      setPeerName(s.remoteName);
      setError(null);
      setReplyLink(null);
      setPhase("linked");
      if (redialTimer.current) clearInterval(redialTimer.current);
      redialTimer.current = null;
      const lost = (closed: boolean) => {
        if (session.current !== s) return;
        if (!unfinished()) {
          // Nothing in flight: a closed link just ends the session.
          if (closed) endSession.current("The other phone disconnected.");
          return;
        }
        setPhase("lost");
        // The phone that showed the QR re-dials through the mailbox until the other answers.
        if (host.current && !redialTimer.current) {
          const h = host.current;
          void h.redial();
          redialTimer.current = setInterval(() => void h.redial(), 8000);
        }
      };
      l.onClose(() => lost(true));
      // The channel only reports "closed" once ICE gives up, which can take half a minute.
      s.pc.addEventListener("connectionstatechange", () => {
        const st = s.pc.connectionState;
        if (st === "disconnected" || st === "failed") lost(st === "failed");
        else if (st === "connected" && session.current === s) setPhase((p) => (p === "lost" ? "linked" : p));
      });
      void refreshPath(s, setPath);
      // Both directions on one channel: requests this phone sends get responses through the
      // transport, requests the other phone sends are served by the receiver.
      transport.current.attach(l);
      receiver?.attach(l);
      if (!job.current && pickedRef.current.length) startJob();
    },
    [receiver, startJob, unfinished],
  );

  const pairingOpts = useMemo(() => ({ name, signal: signalUrl, framing, onLinked, onMailbox: setMailboxOnline }), [name, onLinked]);

  // ---- sender ------------------------------------------------------------------
  /** Tap Send: the picker opens and, while it's up, the offer is built (ICE gathered). */
  const startSend = useCallback(() => {
    input.current?.click(); // first, inside the tap: iOS only opens pickers from a user gesture
    setError(null);
    setRole("send");
    setPhase("host");
    if (host.current) return;
    const h = new HostPairing(pairingOpts);
    host.current = h;
    h.start().then(setHostLink, fail);
  }, [pairingOpts, fail]);

  const addFiles = useCallback(
    (p: Picked[]) => {
      if (!p.length) return;
      marks.current.picked = performance.now();
      const finished = job.current && ["complete", "cancelled", "failed"].includes(job.current.state);
      const next = finished ? dedupe(p) : dedupe([...pickedRef.current, ...p]);
      pickedRef.current = next;
      setPicked(next);
      // Already connected ("Send more", "Send files back", or picked after pairing): start now,
      // and put away whatever finished screen was showing.
      if (link.current?.isOpen && (!job.current || finished)) {
        clearReceived.current();
        job.current = null;
        startJob();
      }
    },
    [startJob],
  );

  // Offline pairing: a reply scanned with the Camera app opens in a new tab and hands it here.
  useEffect(() => {
    if (!channel) return;
    const on = (ev: MessageEvent<{ answer?: string }>) => ev.data.answer && host.current && void host.current.takeReply(ev.data.answer).catch(fail);
    channel.addEventListener("message", on);
    return () => channel.removeEventListener("message", on);
  }, [fail]);

  // ---- receiver ----------------------------------------------------------------
  const scanned = useCallback(
    async (text: string) => {
      setError(null);
      setPhase("connecting");
      void navigator.storage?.persist?.().catch(() => undefined);
      try {
        guest.current ??= new GuestPairing(pairingOpts);
        const reply = await guest.current.scan(text);
        if (reply) {
          setReplyLink(reply);
          setPhase((p) => (p === "connecting" ? "reply" : p));
        }
      } catch (e) {
        fail(e);
        setPhase("scan");
      }
    },
    [pairingOpts, fail],
  );

  const startReceive = useCallback(() => {
    setError(null);
    setRole("receive");
    setPhase("scan");
  }, []);

  useEffect(() => {
    if (initialCode) void scanned(initialCode);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // A code link opened in a tab that already shows the app only changes the hash.
  useEffect(() => {
    const on = () => {
      if (!/[#&]o=[DP][A-Za-z0-9_-]+/.test(location.hash) || roleRef.current === "send" || link.current?.isOpen) return;
      const href = location.href;
      history.replaceState(null, "", location.pathname + location.search);
      setRole("receive");
      void scanned(href);
    };
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, [scanned]);

  useWakeLock(phase === "linked" || phase === "lost");

  /** Back to the start. Received files stay in storage until saved. */
  const reset = useCallback(() => {
    void job.current?.cancel();
    job.current = null;
    transport.current = new PeerTransport();
    host.current?.stop();
    guest.current?.stop();
    host.current = null;
    guest.current = null;
    session.current = null;
    link.current = null;
    if (redialTimer.current) clearInterval(redialTimer.current);
    redialTimer.current = null;
    pickedRef.current = [];
    setPicked([]);
    setHostLink(null);
    setReplyLink(null);
    setPath(null);
    setPeerName("");
    setError(null);
    setRole(null);
    setPhase("home");
  }, []);
  clearReceived.current = () => {
    const done = receiver?.list().filter((t) => t.filesDone === t.files.length) ?? [];
    if (done.length) setDismissed((d) => new Set([...d, ...done.map((t) => t.id)]));
  };
  endSession.current = (message?: string) => {
    reset();
    if (message) setError(message);
  };

  /** Lost for good: show a fresh code (sender) or scan again (receiver). Progress is kept. */
  const repair = useCallback(() => {
    if (host.current) {
      setHostLink(null);
      setPhase("host");
      host.current.start().then(setHostLink, fail);
    } else {
      setPhase("scan");
    }
  }, [fail]);

  // Desktop: drop files anywhere to send.
  useEffect(() => {
    if (isMobile) return;
    let depth = 0;
    const enter = (e: DragEvent) => {
      if (!e.dataTransfer?.types.includes("Files")) return;
      e.preventDefault();
      depth++;
      setDragging(true);
    };
    const over = (e: DragEvent) => e.dataTransfer?.types.includes("Files") && e.preventDefault();
    const leave = () => (depth = Math.max(0, depth - 1)) === 0 && setDragging(false);
    const drop = (e: DragEvent) => {
      e.preventDefault();
      depth = 0;
      setDragging(false);
      // Connected: either side can send. Not connected: only the start screen begins a send.
      if (!e.dataTransfer || (roleRef.current === "receive" && !link.current?.isOpen)) return;
      const dt = e.dataTransfer;
      void fromDataTransfer(dt).then((p) => {
        if (!p.length) return;
        if (!roleRef.current) {
          setRole("send");
          setPhase("host");
          if (!host.current) {
            host.current = new HostPairing(pairingOpts);
            host.current.start().then(setHostLink, fail);
          }
        }
        addFiles(p);
      });
    };
    window.addEventListener("dragenter", enter);
    window.addEventListener("dragover", over);
    window.addEventListener("dragleave", leave);
    window.addEventListener("drop", drop);
    return () => {
      window.removeEventListener("dragenter", enter);
      window.removeEventListener("dragover", over);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("drop", drop);
    };
  }, [addFiles, pairingOpts, fail]);

  if (initialReply) return <Handoff answer={initialReply} />;

  // ---- what to show --------------------------------------------------------------
  const j = job.current;
  const snap = j?.snapshot() ?? null;
  const incoming = receiver?.list().filter((t) => !dismissed.has(t.id)).sort((a, b) => b.createdAt - a.createdAt)[0] ?? null;
  // Two browsers often report the same generic name ("Windows PC"): tell them apart.
  const peer = peerName ? (peerName === name ? `the other ${peerName}` : peerName) : role === "send" ? "the receiver" : "the sender";
  const flow = flowState({ phase, role, picked: picked.length, snap, incoming, offer: Boolean(offer) });

  let screen: { key: string; body: ReactNode };
  if (offer) {
    screen = { key: "accept", body: <AcceptCard offer={offer.offer} from={peer} onDecide={offer.decide} /> };
  } else if (phase === "lost") {
    const pct = role === "send" ? (snap ? pctOf(snap.bytesDone, snap.bytesTotal) : 0) : incoming ? pctOf(incoming.bytesDone, incoming.bytesTotal) : 0;
    screen = { key: "lost", body: <Interrupted pct={pct} role={role} peer={peer} auto={Boolean(signalUrl)} onRepair={repair} /> };
  } else if (phase === "linked") {
    // Connected: either phone can send. What's moving comes first, then what just finished.
    const sending = Boolean(j && snap && snap.state !== "complete" && snap.state !== "cancelled");
    const receiving = Boolean(incoming && incoming.filesDone < incoming.files.length);
    const sendCard =
      j && snap && sending ? (
        <TransferCard
          key="send"
          testId="send-progress"
          state={snap.state}
          verb={verbFor(flowOf("send", snap, null), peer)}
          fileName={j.files[snap.currentFile]?.name ?? j.label}
          bytesDone={snap.bytesDone}
          bytesTotal={snap.bytesTotal}
          speed={snap.speed}
          average={snap.average}
          eta={snap.state === "running" && snap.bytesDone > 0 ? snap.etaSeconds : null}
          filesLeft={snap.filesTotal - snap.filesDone - snap.filesSkipped}
          message={snap.state === "failed" ? plainError(snap.message ?? "The transfer stopped.") : null}
          onCancel={() => void j.cancel().then(() => (job.current = null))}
          live={snap.state === "running"}
        />
      ) : null;
    const recvCard = incoming && receiving ? <ReceiveCard key="recv" t={incoming} receiver={receiver!} peer={peer} flow={flowOf("receive", null, incoming)} /> : null;
    if (sendCard || recvCard) {
      screen = { key: `moving-${sendCard ? "s" : ""}${recvCard ? "r" : ""}`, body: <div className="p2p-stack">{sendCard}{recvCard}</div> };
    } else if (incoming && incoming.filesDone === incoming.files.length) {
      screen = {
        key: `rdone-${incoming.id}`,
        body: (
          <Complete sent={false} files={incoming.files.length} bytes={incoming.bytesTotal} peer={peer} seconds={elapsed(incoming.id, true)}>
            <Saved t={incoming} receiver={receiver!} onDone={() => setDismissed((d) => new Set(d).add(incoming.id))} onSendBack={() => input.current?.click()} />
          </Complete>
        ),
      };
    } else if (j && snap?.state === "complete") {
      screen = {
        key: `done-${j.id}`,
        body: (
          <Complete sent files={snap.filesTotal} bytes={snap.bytesTotal} peer={peer} seconds={snap.elapsedSeconds}>
            <div className="p2p-actions">
              <button className="btn btn-primary btn-lg" onClick={() => input.current?.click()}>
                <Plus size={20} strokeWidth={1.75} /> Send more
              </button>
              <button className="btn btn-glass btn-lg" onClick={() => ((job.current = null), setTick((n) => n + 1))}>
                Done
              </button>
            </div>
          </Complete>
        ),
      };
    } else {
      screen = { key: "linked", body: <Linked peer={peer} path={path} onPick={() => input.current?.click()} onLeave={reset} /> };
    }
  } else if (phase === "connecting") {
    screen = { key: "connecting", body: <Connecting role={role} /> };
  } else if (phase === "host") {
    screen = {
      key: picked.length ? "host" : "selecting",
      body: picked.length ? (
        <ShowCode link={hostLink} picked={picked} onAdd={() => input.current?.click()} onClear={() => ((pickedRef.current = []), setPicked([]))} onScanReply={() => setPhase("host-scan")} onCancel={reset} offline={!signalUrl || mailboxOnline === false} />
      ) : (
        <Selecting onPick={() => input.current?.click()} onCancel={reset} />
      ),
    };
  } else if (phase === "host-scan") {
    screen = {
      key: "host-scan",
      body: (
        <Panel title="Scan the receiver's reply" lead="Only needed without internet. The receiver's phone shows a reply code after it scans yours." onBack={() => setPhase("host")} backLabel="Show my code">
          <Scanner hint="Hold this phone over the other phone's screen." onResult={(t) => void host.current?.takeReply(t).catch(fail)} />
        </Panel>
      ),
    };
  } else if (phase === "scan") {
    screen = {
      key: "scan",
      body: (
        <Panel title="Scan the sender's code" lead="On the other phone, tap Send and choose files. Its code appears right away." onBack={reset} backLabel="Cancel">
          <Scanner hint="Point the camera at the code on the sending phone." onResult={(t) => void scanned(t)} />
        </Panel>
      ),
    };
  } else if (phase === "reply") {
    screen = {
      key: "reply",
      body: (
        <Panel title={`Let ${peer} scan this`} lead="No internet here, so the phones need one more scan. On the sender, tap Scan reply." onBack={reset} backLabel="Cancel">
          <QrPlate link={replyLink ?? ""} label="Reply code for the sender" />
        </Panel>
      ),
    };
  } else {
    screen = { key: "home", body: <Home canReceive={Boolean(receiver)} onSend={startSend} onReceive={startReceive} /> };
  }

  const status = statusOf(phase, path, role);

  return (
    <div className="p2p" data-state={flow} data-role={role ?? "none"} data-dragging={dragging || undefined}>
      <header className="p2p-top">
        <span className="p2p-brand">
          <BrandMark />
          SwiftDrop
        </span>
        <span className="p2p-pill" role="status" aria-label={`Connection: ${status.text}`} {...(path && phase === "linked" ? { "data-testid": "path", "data-kind": path.kind, title: pathLabel(path).detail } : {})}>
          <span className="p2p-dot" data-state={status.dot} />
          {status.text}
        </span>
      </header>

      <div className="p2p-shell">
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
        <aside className="p2p-aside" aria-label="This device and recent transfers">
          <section className="p2p-device">
            <span className="p2p-glyph">{isMobile ? <Smartphone size={17} strokeWidth={1.5} /> : <Monitor size={17} strokeWidth={1.5} />}</span>
            <span className="min-w-0">
              <span className="p2p-row-t truncate">{name}</span>
              <span className="p2p-row-s">This device{peerName && phase === "linked" ? ` · connected to ${peer}` : ""}</span>
            </span>
          </section>
          <Recent />
        </aside>
      </div>

      {debug && (
        <DebugPanel
          sources={(): DebugSources => ({
            flow,
            session: session.current,
            link: link.current,
            job: job.current,
            sinks,
            receiving: incoming,
            marks: marks.current,
          })}
        />
      )}

      <input
        ref={input}
        type="file"
        multiple
        hidden
        onChange={(e) => {
          // File references only: nothing is read, copied, hashed or thumbnailed here.
          const p = fromInput(e.target.files);
          e.target.value = "";
          addFiles(p);
        }}
      />
      {dragging && (
        <div className="p2p-drop" aria-hidden>
          <ArrowUp size={28} strokeWidth={1.5} />
          Drop to send
        </div>
      )}
    </div>
  );
}

// ---- screens -------------------------------------------------------------------

function Home({ canReceive, onSend, onReceive }: { canReceive: boolean; onSend: () => void; onReceive: () => void }) {
  return (
    <section className="p2p-home" aria-label="Start">
      <div className="p2p-hero">
        <div className="p2p-bloom" aria-hidden />
        <Connection state="waiting" left={{ name: thisDevice, kind: selfKind, live: true }} right={{ name: "Other phone", kind: "phone", live: false }} />
      </div>
      <h1 className="p2p-display">
        Send anything.
        <span>Directly.</span>
      </h1>
      <p className="p2p-lead">Phone to phone over your Wi-Fi. No cable, no cloud, no account.</p>
      <div className="p2p-choices">
        <button className="p2p-choice" data-tone="red" onClick={onSend}>
          <span className="p2p-choice-icon">
            <ArrowUp size={22} strokeWidth={2} />
          </span>
          <span className="p2p-choice-t">Send</span>
          <span className="p2p-choice-s">Choose files, show a code</span>
        </button>
        <button className="p2p-choice" onClick={onReceive} disabled={!canReceive}>
          <span className="p2p-choice-icon">
            <ArrowDown size={22} strokeWidth={2} />
          </span>
          <span className="p2p-choice-t">Receive</span>
          <span className="p2p-choice-s">Scan the sender's code</span>
        </button>
      </div>
      {!canReceive && <p className="p2p-note">This browser can't store received files, so it can only send. Receiving needs Safari or Chrome over https.</p>}
    </section>
  );
}

function Selecting({ onPick, onCancel }: { onPick: () => void; onCancel: () => void }) {
  return (
    <section className="p2p-stack" aria-label="Choose files">
      <h1 className="p2p-h1">Choose what to send</h1>
      <p className="p2p-lead">Photos, videos or any file. Your code appears as soon as you pick.</p>
      <div className="p2p-actions">
        <button className="btn btn-primary btn-lg" onClick={onPick}>
          <Plus size={20} strokeWidth={1.75} /> Choose files
        </button>
        <button className="btn btn-ghost btn-lg" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </section>
  );
}

function ShowCode({ link, picked, onAdd, onClear, onScanReply, onCancel, offline }: { link: string | null; picked: Picked[]; onAdd: () => void; onClear: () => void; onScanReply: () => void; onCancel: () => void; offline: boolean }) {
  const total = picked.reduce((s, p) => s + p.file.size, 0);
  return (
    <section className="p2p-stack p2p-code" aria-label="Pairing code">
      <div className="p2p-stack-tight">
        <h1 className="p2p-h1">Scan to receive</h1>
        <p className="p2p-lead">On the other phone, open SwiftDrop and tap Receive, or point its Camera here.</p>
      </div>
      {link ? <QrPlate link={link} label="Pairing code for the receiving phone" /> : <div className="p2p-qr p2p-qr-pending" aria-label="Preparing the code" />}
      <p className="p2p-waiting">
        <LoaderCircle size={15} className="p2p-spin" aria-hidden /> Waiting for the receiver
      </p>
      <div className="p2p-glass p2p-selection">
        <FileGlyph name={picked[0]!.file.name} type={picked[0]!.file.type} />
        <span className="min-w-0">
          <span className="p2p-row-t p2p-clamp">{labelFor(picked)}</span>
          <span className="p2p-row-s num">
            {plural(picked.length, "file")} · {formatBytes(total)}
          </span>
        </span>
        <button className="btn btn-ghost btn-sm" onClick={onAdd}>
          Add
        </button>
        <button className="btn btn-ghost btn-sm btn-icon" aria-label="Clear selection" onClick={onClear}>
          <X size={16} strokeWidth={1.75} />
        </button>
      </div>
      <div className="p2p-actions">
        <button className="btn btn-glass btn-lg" onClick={onCancel}>
          Cancel
        </button>
        {offline && (
          <button className="btn btn-glass btn-lg" onClick={onScanReply}>
            <ScanLine size={18} strokeWidth={1.75} /> Scan reply
          </button>
        )}
      </div>
      {offline && <p className="p2p-note text-center">No internet here, so the receiver will show a reply code for this phone to scan.</p>}
    </section>
  );
}

function Panel({ title, lead, children, onBack, backLabel }: { title: string; lead: string; children: ReactNode; onBack: () => void; backLabel: string }) {
  return (
    <section className="p2p-stack" aria-label={title}>
      <div className="p2p-stack-tight">
        <h1 className="p2p-h1">{title}</h1>
        <p className="p2p-lead">{lead}</p>
      </div>
      {children}
      <button className="btn btn-ghost btn-lg w-full" onClick={onBack}>
        {backLabel}
      </button>
    </section>
  );
}

function Connecting({ role }: { role: "send" | "receive" | null }) {
  return (
    <section className="p2p-stack p2p-center" aria-label="Connecting">
      <Connection state="connecting" left={{ name: thisDevice, kind: selfKind, live: true }} right={{ name: "Other phone", kind: "phone", live: false }} flow={role === "receive" ? "left" : "right"} />
      <h1 className="p2p-h1">Connecting</h1>
      <p className="p2p-lead">Setting up a direct link between the two phones.</p>
    </section>
  );
}

function Linked({ peer, path, onPick, onLeave }: { peer: string; path: PathInfo | null; onPick: () => void; onLeave: () => void }) {
  return (
    <section className="p2p-stack p2p-center" aria-label="Connected">
      <div className="p2p-hero p2p-hero-sm">
        <div className="p2p-bloom" aria-hidden />
        <Connection state="connected" left={{ name: thisDevice, kind: selfKind, live: true }} right={{ name: cap(peer), kind: /PC|Mac/.test(peer) ? "pc" : "phone", live: true }} />
      </div>
      <div className="p2p-stack-tight items-center">
        <h1 className="p2p-h1">Connected to {cap(peer)}</h1>
        <PathBadge path={path} />
      </div>
      <div className="p2p-glass p2p-ready">
        <p className="p2p-row-t">Ready to send</p>
        <p className="p2p-row-s">
          {isMobile ? "Either phone can send now. Pick files to start." : "Either side can send now. Pick files, or drop them anywhere on this window."}
        </p>
        <button className="btn btn-primary btn-lg w-full" onClick={onPick}>
          Select files
        </button>
      </div>
      <button className="btn btn-ghost btn-sm" onClick={onLeave}>
        Disconnect
      </button>
    </section>
  );
}

function AcceptCard({ offer, from, onDecide }: { offer: IncomingOffer; from: string; onDecide: (ok: boolean) => void }) {
  const media = offer.files.filter((f) => ["image", "video"].includes(kindOf(f.name, f.type))).length;
  return (
    <section className="p2p-stack" role="dialog" aria-label="Incoming files" aria-describedby="incoming-summary">
      <div className="p2p-stack-tight">
        <h1 className="p2p-h1">
          {cap(from)} wants to send {plural(offer.files.length, "file")}
        </h1>
        <p id="incoming-summary" className="p2p-lead num">
          {formatBytes(offer.totalBytes)}
          {media > 0 && media < offer.files.length && ` · ${plural(media, "photo or video", "photos and videos")}`}
        </p>
      </div>
      <ul className="p2p-glass p2p-list">
        {offer.files.slice(0, 50).map((f) => (
          <li key={f.id}>
            <FileGlyph name={f.name} type={f.type} />
            <span className="truncate min-w-0">
              {f.relDir ? <span className="p2p-dim">{f.relDir}/</span> : null}
              {f.name}
            </span>
            <span className="p2p-row-s num">{formatBytes(f.size)}</span>
          </li>
        ))}
        {offer.files.length > 50 && <li className="p2p-row-s">and {formatCount(offer.files.length - 50)} more</li>}
      </ul>
      <div className="p2p-actions">
        <button className="btn btn-glass btn-lg" onClick={() => onDecide(false)}>
          Decline
        </button>
        <button className="btn btn-primary btn-lg" onClick={() => onDecide(true)}>
          Accept
        </button>
      </div>
    </section>
  );
}

const fmtPct = (v: number) => String(Math.min(100, Math.max(0, Math.floor(v))));
const fmtRate = (v: number) => (v >= 100 ? v.toFixed(0) : v.toFixed(1));

/** The transfer itself: what's moving, how far, how fast. Same card both directions. */
function TransferCard(p: {
  testId: string;
  state: string;
  verb: string;
  fileName: string;
  bytesDone: number;
  bytesTotal: number;
  speed: number;
  average: number;
  eta: number | null;
  filesLeft: number;
  message: string | null;
  live: boolean;
  onCancel?: () => void;
}) {
  const pct = pctOf(p.bytesDone, p.bytesTotal);
  return (
    <section className="p2p-transfer" data-testid={p.testId} data-state={p.state} aria-label="Transfer in progress">
      <div className="p2p-transfer-head">
        <h1 className="p2p-file truncate">{p.fileName}</h1>
        <span className="p2p-verb">
          <span className="p2p-dot" data-state={p.live ? "live" : p.message ? "warn" : undefined} />
          {p.verb}
        </span>
      </div>

      <div className="p2p-glass p2p-meter">
        <div className="p2p-meter-top">
          <span className="p2p-speed num">
            <AnimatedNumber value={p.speed / 1e6} format={fmtRate} />
            <small>MB/s</small>
          </span>
          <span className="p2p-pct num">
            <AnimatedNumber value={pct} format={fmtPct} />%
          </span>
        </div>
        <div
          className="p2p-bar"
          role="progressbar"
          aria-label="Transfer progress"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={Math.floor(pct)}
          aria-valuetext={`${Math.floor(pct)}%, ${formatBytes(p.bytesDone)} of ${formatBytes(p.bytesTotal)}`}
        >
          <span style={{ transform: `scaleX(${pct / 100})` }} />
        </div>
        <div className="p2p-meter-foot num">
          <span>
            {formatBytes(p.bytesDone)} / {formatBytes(p.bytesTotal)}
          </span>
          <span>{p.eta === null ? "Starting" : humanEta(p.eta)}</span>
        </div>
        <div className="p2p-meter-foot num">
          <span>{p.filesLeft > 0 ? `${plural(p.filesLeft, "file")} remaining` : "Last file"}</span>
          <span>{p.average >= 50_000 ? `avg ${fmtRate(p.average / 1e6)} MB/s` : ""}</span>
        </div>
      </div>

      {p.message && (
        <p className="p2p-alert" role="alert">
          {p.message}
        </p>
      )}
      {p.onCancel && (
        <button className="btn btn-glass btn-lg w-full" onClick={p.onCancel}>
          Cancel
        </button>
      )}
      <p className="p2p-note">Keep both screens on until it finishes.</p>
    </section>
  );
}

function ReceiveCard({ t, receiver, peer, flow }: { t: ReceivedTransfer; receiver: PeerReceiver; peer: string; flow: FlowState }) {
  const speed = useRate(t.bytesDone);
  const avg = t.bytesDone / Math.max(0.001, elapsed(t.id, false) || 0.001);
  const current = t.files.find((f) => f.state !== "complete" && f.state !== "skipped") ?? t.files[t.files.length - 1]!;
  return (
    <TransferCard
      testId="receive-progress"
      state={flow === "COMPLETED" ? "complete" : "active"}
      verb={flow === "VERIFYING" ? "Verifying" : `Receiving from ${peer}`}
      fileName={current.name}
      bytesDone={t.bytesDone}
      bytesTotal={t.bytesTotal}
      speed={speed}
      average={elapsed(t.id, false) > 1 ? avg : 0}
      eta={speed > 0 ? (t.bytesTotal - t.bytesDone) / speed : t.bytesDone > 0 ? Infinity : null}
      filesLeft={t.files.length - t.filesDone}
      message={null}
      live={speed > 0}
      onCancel={() => void receiver.forget(t.id)}
    />
  );
}

function Complete({ sent, files, bytes, peer, seconds, children }: { sent: boolean; files: number; bytes: number; peer: string; seconds: number; children?: ReactNode }) {
  return (
    <section className="p2p-stack" data-testid={sent ? "send-progress" : "receive-progress"} data-state="complete" aria-label="Transfer complete">
      <div className="p2p-done">
        <div className="p2p-mark" aria-hidden>
          <Check size={34} strokeWidth={2.25} />
        </div>
        <h1 className="p2p-h1">Transfer complete</h1>
        <span className="p2p-verified">
          <Check size={14} strokeWidth={2.5} /> Verified
        </span>
        <p className="p2p-lead num">
          {plural(files, "file")} · {formatBytes(bytes)}
        </p>
        <p className="p2p-note num">
          {sent ? `Sent to ${peer}` : `Received from ${peer}`}
          {seconds > 0 ? ` in ${humanDuration(seconds)}` : ""}
        </p>
      </div>
      {children}
    </section>
  );
}

function Saved({ t, receiver, onDone, onSendBack }: { t: ReceivedTransfer; receiver: PeerReceiver; onDone: () => void; onSendBack: () => void }) {
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
    <div className="p2p-stack">
      <div className="p2p-actions">
        <button className="btn btn-primary btn-lg" disabled={saving} onClick={() => void saveAll()}>
          {saving ? <LoaderCircle size={20} className="p2p-spin" /> : <Share size={20} strokeWidth={1.75} />} {t.files.length === 1 ? "Save" : "Save all"}
        </button>
        <button className="btn btn-glass btn-lg" onClick={onDone}>
          Done
        </button>
      </div>
      <ul className="p2p-glass p2p-list">
        {t.files.slice(0, 200).map((f) => (
          <li key={f.id}>
            <FileGlyph name={f.name} type={f.type} />
            <span className="truncate min-w-0">{[...f.relDir, f.name].join("/")}</span>
            <button className="btn btn-ghost btn-sm btn-icon" aria-label={`Save ${f.name}`} onClick={() => void receiver.file(t, f).then(download)}>
              <Download size={16} strokeWidth={1.75} />
            </button>
          </li>
        ))}
      </ul>
      <p className="p2p-note">Received files stay in this browser until you save them to Photos or Files.</p>
      <button className="p2p-textlink" onClick={onSendBack}>
        <ArrowUp size={15} strokeWidth={1.75} /> Send files back
      </button>
    </div>
  );
}

function Interrupted({ pct, role, peer, auto, onRepair }: { pct: number; role: "send" | "receive" | null; peer: string; auto: boolean; onRepair: () => void }) {
  return (
    <section className="p2p-stack" aria-label="Connection interrupted">
      <div className="p2p-stack-tight">
        <h1 className="p2p-h1">Reconnecting</h1>
        <p className="p2p-lead">Your transfer is safe. Nothing that already arrived is sent again.</p>
      </div>
      <div className="p2p-glass p2p-meter">
        <div className="p2p-bar" data-tone="paused" role="progressbar" aria-label="Transfer progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.floor(pct)}>
          <span style={{ transform: `scaleX(${pct / 100})` }} />
        </div>
        <div className="p2p-meter-foot num">
          <span>Paused at {Math.floor(pct)}%</span>
          <span className="flex items-center gap-2">
            <LoaderCircle size={14} className="p2p-spin" aria-hidden /> {auto ? "Finding the other phone" : "Waiting"}
          </span>
        </div>
      </div>
      <p className="p2p-note">
        {role === "send"
          ? `Keep both phones on the same Wi-Fi with the screen on. If it doesn't come back, show a new code and let ${peer} scan it.`
          : `Keep both phones on the same Wi-Fi with the screen on. If it doesn't come back, scan the new code on ${peer}.`}
      </p>
      <button className="btn btn-glass btn-lg w-full" onClick={onRepair}>
        {role === "send" ? (
          <>
            <RefreshCw size={18} strokeWidth={1.75} /> Show a new code
          </>
        ) : (
          <>
            <ScanLine size={18} strokeWidth={1.75} /> Scan again
          </>
        )}
      </button>
    </section>
  );
}

function Recent() {
  const items = useHistory();
  return (
    <section className="p2p-recent">
      <h2 className="p2p-h2">Recent transfers</h2>
      {items.length === 0 ? (
        <p className="p2p-note">Nothing yet. Files you send or receive here show up in this list.</p>
      ) : (
        <ul className="p2p-recent-list">
          {items.slice(0, 6).map((i) => (
            <RecentRow key={`${i.dir}-${i.id}`} item={i} />
          ))}
        </ul>
      )}
    </section>
  );
}

function RecentRow({ item }: { item: HistoryItem }) {
  const Icon = item.kind === "video" ? Film : item.kind === "image" ? ImageIcon : item.kind === "mixed" ? Files : FileText;
  return (
    <li className="p2p-glass p2p-recent-row">
      <span className="p2p-glyph">
        <Icon size={17} strokeWidth={1.5} />
      </span>
      <span className="min-w-0">
        <span className="p2p-row-t p2p-clamp">{item.label}</span>
        <span className="p2p-row-s num truncate">
          {plural(item.files, "file")} · {formatBytes(item.bytes)} · {item.dir === "sent" ? `to ${item.peer}` : `from ${item.peer}`}
        </span>
      </span>
      <span className="p2p-row-s">{timeAgo(item.at)}</span>
    </li>
  );
}

function QrPlate({ link, label }: { link: string; label: string }) {
  const qr = useMemo(() => {
    const m = QRCode.create(link, { errorCorrectionLevel: "L" }).modules;
    let s = "";
    for (let i = 0; i < m.data.length; i++) s += String.fromCharCode(m.data[i]!);
    return { size: m.size, bits: btoa(s) };
  }, [link]);
  return (
    <div className="p2p-qr" data-testid="signal" data-signal={link}>
      <QrCode size={qr.size} bits={qr.bits} label={label} />
    </div>
  );
}

function PathBadge({ path }: { path: PathInfo | null }) {
  const t = path ? pathLabel(path) : null;
  return (
    <span className="p2p-path" title={t?.detail}>
      <span className="p2p-dot" data-state={path ? "live" : undefined} />
      {t ? t.title : "Direct · Checking the network path"}
    </span>
  );
}

function BrandMark() {
  return (
    <span className="p2p-mark-sm" aria-hidden>
      <Send size={13} strokeWidth={2.5} />
    </span>
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

/** Opened by the Camera app on the sender with a reply (offline pairing): pass it to the tab that asked. */
function Handoff({ answer }: { answer: string }) {
  useEffect(() => channel?.postMessage({ answer }), [answer]);
  return (
    <main className="p2p p2p-handoff">
      <div className="p2p-stack p2p-center">
        <span className="p2p-mark">
          <Smartphone size={30} strokeWidth={1.75} />
        </span>
        <h1 className="p2p-h1">Reply received</h1>
        <p className="p2p-lead">Switch back to the SwiftDrop tab that showed the code. The phones connect from there.</p>
      </div>
    </main>
  );
}

// ---- helpers -------------------------------------------------------------------

function flowState(x: { phase: Phase; role: "send" | "receive" | null; picked: number; snap: ReturnType<TransferJob["snapshot"]> | null; incoming: ReceivedTransfer | null; offer: boolean }): FlowState {
  if (x.offer) return "AWAITING_ACCEPT";
  switch (x.phase) {
    case "home":
      return "IDLE";
    case "host":
      return x.picked ? "WAITING_FOR_RECEIVER" : "SELECTING";
    case "host-scan":
    case "scan":
      return "SCANNING";
    case "reply":
    case "connecting":
      return "CONNECTING";
    case "lost":
      return "RECONNECTING";
    case "linked":
      break;
  }
  const send = x.snap ? flowOf("send", x.snap, null) : null;
  const recv = x.incoming ? flowOf("receive", null, x.incoming) : null;
  const moving = (f: FlowState | null) => f !== null && f !== "COMPLETED" && f !== "CONNECTED";
  if (moving(send)) return send!;
  if (moving(recv)) return recv!;
  if (send === "COMPLETED" || recv === "COMPLETED") return "COMPLETED";
  return "CONNECTED";
}

/** One direction's state on a live connection. */
function flowOf(dir: "send" | "receive", s: ReturnType<TransferJob["snapshot"]> | null, t: ReceivedTransfer | null): FlowState {
  if (dir === "send") {
    if (!s || s.state === "cancelled") return "CONNECTED";
    if (s.state === "queued" || s.state === "preparing" || s.state === "awaiting-decision") return "AWAITING_ACCEPT";
    if (s.state === "running") return s.bytesDone === 0 ? "PREPARING_FIRST_FILE" : s.bytesDone >= s.bytesTotal ? "VERIFYING" : "TRANSFERRING";
    if (s.state === "reconnecting") return "RECONNECTING";
    if (s.state === "paused") return "PAUSED";
    if (s.state === "complete") return "COMPLETED";
    return "FAILED";
  }
  if (!t) return "CONNECTED";
  if (t.filesDone === t.files.length) return "COMPLETED";
  if (t.bytesDone === 0) return "PREPARING_FIRST_FILE";
  return t.bytesDone >= t.bytesTotal ? "VERIFYING" : "TRANSFERRING";
}

function verbFor(flow: FlowState, peer: string): string {
  switch (flow) {
    case "AWAITING_ACCEPT":
      return `Waiting for ${peer} to accept`;
    case "PREPARING_FIRST_FILE":
      return "Starting";
    case "VERIFYING":
      return "Verifying";
    case "RECONNECTING":
      return "Reconnecting";
    case "PAUSED":
      return "Paused";
    case "FAILED":
      return "Stopped";
    default:
      return `Sending to ${peer}`;
  }
}

function statusOf(phase: Phase, path: PathInfo | null, role: "send" | "receive" | null): { text: string; dot?: "live" | "warn" } {
  if (phase === "linked") return { text: path ? pathLabel(path).title : "Connected", dot: "live" };
  if (phase === "connecting" || phase === "reply") return { text: "Connecting" };
  if (phase === "lost") return { text: "Reconnecting", dot: "warn" };
  if (phase === "host" || phase === "host-scan") return { text: "Waiting for receiver" };
  if (phase === "scan") return { text: role === "receive" ? "Scanning" : "Pairing" };
  return { text: "Not connected" };
}

/** When each received transfer was first shown and when it finished; survives screen swaps. */
const timings = new Map<string, { start: number; end: number | null }>();
function elapsed(id: string, done: boolean): number {
  let t = timings.get(id);
  if (!t) timings.set(id, (t = { start: performance.now(), end: null }));
  if (done && t.end === null) t.end = performance.now();
  return ((t.end ?? performance.now()) - t.start) / 1000;
}

const pctOf = (done: number, total: number) => (total > 0 ? (done / total) * 100 : 100);
/** Sentence-start form of a peer name: only the generic fallback needs it ("iPhone" stays as is). */
const cap = (s: string) => (s.startsWith("the ") ? `T${s.slice(1)}` : s);

function kindSummary(kinds: string[]): HistoryItem["kind"] {
  const set = new Set(kinds.map((k) => (k === "image" || k === "video" ? k : "file")));
  return set.size === 1 ? ([...set][0] as HistoryItem["kind"]) : "mixed";
}

function historyOf(t: ReceivedTransfer, dir: "received", peer: string, seconds: number): HistoryItem {
  return { id: t.id, label: t.label, dir, peer, files: t.files.length, bytes: t.bytesTotal, seconds, at: Date.now(), kind: kindSummary(t.files.map((f) => kindOf(f.name, f.type))) };
}

/** What a selection is called everywhere (manifest, recents): led by a real file name. */
function labelFor(picked: Picked[]): string {
  if (picked.length === 1) return picked[0]!.file.name;
  const folder = describe(picked);
  if (!/\d/.test(folder)) return folder; // a folder name
  return `${picked[0]!.file.name} and ${formatCount(picked.length - 1)} more`;
}

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
  if (/channel closed|no local description|ICE|SDP|RTC|setRemoteDescription/i.test(m)) return "The connection closed before it finished setting up. Try again.";
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

/** Bytes/s over a rolling 3 s window, sampled on the repaint clock. */
function useRate(bytes: number): number {
  const hist = useRef<Array<[number, number]>>([]);
  const now = performance.now();
  const h = hist.current;
  if (!h.length || h[h.length - 1]![1] !== bytes) h.push([now, bytes]);
  while (h.length > 2 && now - h[0]![0] > 3000) h.shift();
  if (h.length < 2) return 0;
  const [t0, b0] = h[0]!;
  // Under 1.5 s of history a rate is a guess (one request landing or not): report none.
  if (now - t0 < 1500) return 0;
  return ((bytes - b0) * 1000) / (now - t0);
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
