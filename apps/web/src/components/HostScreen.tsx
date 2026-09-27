import { Check } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Api, type Pairing } from "../lib/api.ts";
import { fromInput, type Picked } from "../lib/files.ts";
import { send } from "../lib/jobs.ts";
import { currentReading, useAppState, useJobs, useTick } from "../lib/reading.ts";
import { useShortcuts } from "../lib/shortcuts.ts";
import { notify } from "../lib/store.ts";
import { useDropAnywhere } from "../lib/useDrop.ts";
import { Swap } from "../ui/Swap.tsx";
import { Composer } from "./Composer.tsx";
import { Connection, type LinkState } from "./Connection.tsx";
import { JoinPrompt } from "./JoinPrompt.tsx";
import { Offers } from "./Offers.tsx";
import { QrObject } from "./QrObject.tsx";
import { Recent } from "./Recent.tsx";
import { SelectionSheet } from "./SelectionSheet.tsx";
import { TransferFocus } from "./TransferFocus.tsx";

type Stage = "waiting" | "connecting" | "welcome" | "ready" | "transfer";

/** The PC. One focal object per stage; everything else steps back. */
export function HostScreen() {
  const state = useAppState();
  const jobs = useJobs();
  const online = state.devices.filter((d) => d.online);
  const phone = online[0]?.name ?? state.joinRequests[0]?.deviceName ?? "Phone";
  const [picked, setPicked] = useState<Picked[] | null>(null);
  const [reviewing, setReviewing] = useState(false);
  const [dismissed, setDismissed] = useState<string | null>(null);
  const [welcome, setWelcome] = useState(false);
  const filesInput = useRef<HTMLInputElement>(null);
  const folderInput = useRef<HTMLInputElement>(null);

  const reading = currentReading(jobs, state);
  const showReading = reading && reading.key !== dismissed;
  const moving = reading?.state === "running" || reading?.state === "active";
  useTick(250, Boolean(reading && !["complete", "cancelled"].includes(reading.state)));

  // A freshly approved phone gets its "connected" moment before the interface moves on.
  const sawJoin = useRef(false);
  if (state.joinRequests.length) sawJoin.current = true;
  const prevOnline = useRef(online.length);
  useEffect(() => {
    const was = prevOnline.current;
    prevOnline.current = online.length;
    if (was === 0 && online.length > 0 && sawJoin.current) {
      sawJoin.current = false;
      setWelcome(true);
      const t = setTimeout(() => setWelcome(false), 1600);
      return () => clearTimeout(t);
    }
  }, [online.length]);

  const canSend = state.devices.length > 0;
  const openFiles = useCallback(() => filesInput.current?.click(), []);
  const over = useDropAnywhere(canSend && !moving, (p) => setPicked(p));
  const activeJob = reading?.job && !["complete", "cancelled"].includes(reading.job.state) ? reading.job : null;
  useShortcuts({ job: activeJob, onOpen: canSend ? openFiles : null });

  const stage: Stage =
    showReading && reading.state !== "cancelled"
      ? "transfer"
      : online.length === 0
        ? state.joinRequests.length
          ? "connecting"
          : "waiting"
        : welcome
          ? "welcome"
          : "ready";

  const linkState: LinkState = stage === "waiting" ? "waiting" : stage === "connecting" ? "connecting" : moving ? "transferring" : "connected";
  const flow = reading?.flow === "to-pc" ? "right" : "left";

  const startSend = () => {
    if (!picked?.length) return;
    send(picked, "to-guest");
    setPicked(null);
  };

  return (
    <div className="flex flex-col gap-24 md:gap-32">
      <section className="flex flex-col items-center text-center gap-12 pt-6 md:pt-14 min-h-[560px]" aria-live="polite">
        <Swap k={stage === "transfer" ? `transfer` : stage} className="w-full">
          {stage === "waiting" || stage === "connecting" ? (
            <Pairing phone={phone} connecting={stage === "connecting"} />
          ) : stage === "welcome" ? (
            <div className="flex flex-col items-center gap-6 pt-16">
              <div className="check" aria-hidden>
                <Check size={28} strokeWidth={2.25} style={{ color: "var(--accent)" }} />
              </div>
              <h1 className="t-display">{phone} connected</h1>
              <p className="t-lead">Directly, over your Wi-Fi.</p>
            </div>
          ) : stage === "transfer" ? (
            <div className="w-full max-w-[720px] mx-auto text-left">
              <TransferFocus r={reading!} rtt={state.rtt} peer={phone} perspective="host" onDone={() => setDismissed(reading!.key)} />
            </div>
          ) : (
            <div className="w-full max-w-[720px] mx-auto flex flex-col gap-8">
              <div className="flex flex-col gap-3">
                <h1 className="t-h1">{online.length ? `${phone} is connected` : `${phone} is paired`}</h1>
                <p className="t-lead">
                  {online.length ? "Drop files to send them over. Anything sent from the phone lands in " : "Open SwiftDrop on the phone to reconnect. Files from it land in "}
                  <button
                    className="bg-transparent border-0 p-0 cursor-pointer mono"
                    style={{ color: "var(--text)", textDecoration: "underline", textUnderlineOffset: 4, textDecorationColor: "var(--hairline-2)" }}
                    title="Open this folder"
                    onClick={() => void Api.openFolder().catch((e: Error) => notify(e.message, "error"))}
                  >
                    {state.destination || "your chosen folder"}
                  </button>
                </p>
              </div>
              <Composer
                target={phone}
                picked={picked}
                over={over}
                onChooseFiles={openFiles}
                onChooseFolder={() => folderInput.current?.click()}
                onSend={startSend}
                onClear={() => setPicked(null)}
                onReview={() => setReviewing(true)}
              />
            </div>
          )}
        </Swap>

        {stage !== "waiting" && stage !== "connecting" && (
          <div className="w-full max-w-[520px] mx-auto">
            <Connection
              state={linkState}
              left={{ name: "This PC", kind: "pc", live: true }}
              right={{ name: phone, kind: "phone", live: online.length > 0 }}
              flow={flow}
              speed={reading?.speed ?? 0}
              target={over ? "right" : null}
              compact
              caption={
                <>
                  <span className="dot" data-state={online.length ? "live" : undefined} />
                  {moving ? (reading?.flow === "to-pc" ? `Receiving from ${phone}` : `Sending to ${phone}`) : online.length ? "Connected locally" : "Paired · not open"}
                </>
              }
            />
          </div>
        )}
      </section>

      <div className={`grid gap-16 md:gap-12 ${state.offers.length ? "md:grid-cols-2" : ""}`}>
        <Recent perspective="host" />
        <Offers perspective="host" />
      </div>

      <input ref={filesInput} type="file" multiple hidden onChange={(e) => (setPicked(fromInput(e.target.files)), (e.target.value = ""))} />
      <input
        ref={folderInput}
        type="file"
        hidden
        {...({ webkitdirectory: "", directory: "" } as Record<string, string>)}
        onChange={(e) => (setPicked(fromInput(e.target.files)), (e.target.value = ""))}
      />

      {stage !== "waiting" && stage !== "connecting" && <JoinPrompt />}

      {over && (
        <div className="drag-veil" aria-hidden>
          <div className="text-center swap-enter">
            <div className="t-display">Drop to send</div>
            <p className="t-lead mt-3">to {phone}</p>
          </div>
        </div>
      )}

      {reviewing && picked && (
        <SelectionSheet
          picked={picked}
          target={phone}
          onClose={() => setReviewing(false)}
          onSend={(files) => {
            setReviewing(false);
            send(files, "to-guest");
            setPicked(null);
          }}
        />
      )}
    </div>
  );
}

function Pairing({ phone, connecting }: { phone: string; connecting: boolean }) {
  const [p, setP] = useState<Pairing | null>(null);
  const [expired, setExpired] = useState(false);
  const { joinRequests } = useAppState();
  const req = joinRequests[0];

  const load = useCallback(async (rotate = false) => {
    try {
      const x = await Api.pairing(undefined, rotate);
      setP(x);
      setExpired(false);
    } catch (e) {
      notify((e as Error).message, "error");
    }
  }, []);

  useEffect(() => void load(), [load]);
  useEffect(() => {
    if (!p) return;
    const t = setTimeout(() => (document.visibilityState === "visible" ? void load() : setExpired(true)), Math.max(1000, p.expiresAt - Date.now() + 200));
    return () => clearTimeout(t);
  }, [p, load]);

  const noNetwork = p && !p.url;
  const host = p?.manualUrl?.replace(/^http:\/\//, "");

  return (
    <div className="flex flex-col items-center gap-10">
      <div className="flex flex-col items-center gap-4 max-w-[640px]">
        <h1 className="t-display rise">{connecting ? "Almost there." : "Transfer without the cloud."}</h1>
        <p className="t-lead rise" style={{ "--i": 1 } as React.CSSProperties}>
          {connecting ? `Allow ${req?.deviceName ?? phone} to connect to this PC.` : "Your files move directly between your devices, over your own Wi-Fi."}
        </p>
      </div>

      {noNetwork ? (
        <div className="max-w-md flex flex-col gap-2">
          <p className="t-h2">This PC isn't on a network yet</p>
          <p className="t-body">Join the same Wi-Fi as your phone, or turn on your phone's hotspot and connect this PC to it.</p>
        </div>
      ) : (
        <div className="flex flex-col items-center gap-6 rise" style={{ "--i": 2 } as React.CSSProperties}>
          <QrObject pairing={p} state={connecting ? "connecting" : expired ? "expired" : "idle"} onRefresh={() => void load(true)} />
          {connecting && req ? (
            <div className="flex flex-col items-center gap-4 swap-enter">
              <p className="t-body" style={{ color: "var(--text)" }}>
                {req.deviceName} wants to connect
              </p>
              <div className="flex gap-2">
                <button className="btn btn-primary" autoFocus onClick={() => void Api.approve(req.requestId, true).catch((e: Error) => notify(e.message, "error"))}>
                  Allow
                </button>
                <button className="btn btn-ghost" onClick={() => void Api.approve(req.requestId, false).catch(() => undefined)}>
                  Decline
                </button>
              </div>
              <p className="t-small">Only allow a device you're holding.</p>
            </div>
          ) : (
            <div className="flex flex-col items-center gap-2">
              <p className="t-body" style={{ color: "var(--text)" }}>
                Scan with your phone’s camera
              </p>
              {host && p && (
                <p className="t-small">
                  or open <span className="mono" style={{ color: "var(--text-2)" }}>{host}</span> and enter{" "}
                  <span className="mono num" style={{ color: "var(--text)", letterSpacing: "0.12em" }}>
                    {p.code}
                  </span>
                </p>
              )}
            </div>
          )}
        </div>
      )}

      <div className="w-full max-w-[460px] rise" style={{ "--i": 3 } as React.CSSProperties}>
        <Connection
          state={connecting ? "connecting" : "waiting"}
          left={{ name: connecting ? (req?.deviceName ?? "Phone") : "Phone", kind: "phone", live: connecting }}
          right={{ name: "This PC", kind: "pc", live: true }}
          compact
          caption={
            <>
              <span className="dot" data-state={connecting ? "live" : undefined} />
              {connecting ? "Connecting…" : "Same Wi-Fi · No cloud required"}
            </>
          }
        />
      </div>
    </div>
  );
}
