import { formatBytes } from "@swiftdrop/shared";
import { ChevronDown, FolderUp, Images } from "lucide-react";
import { useRef, useState } from "react";
import { deviceLabel, isAndroid, isIOS } from "../lib/env.ts";
import { fromInput, type Picked } from "../lib/files.ts";
import { forgetRecord, resumeRecords, send } from "../lib/jobs.ts";
import { currentReading, useAppState, useJobs, useTick } from "../lib/reading.ts";
import { useShortcuts } from "../lib/shortcuts.ts";
import { Swap } from "../ui/Swap.tsx";
import { Connection } from "./Connection.tsx";
import { Offers } from "./Offers.tsx";
import { Recent } from "./Recent.tsx";
import { SelectionSheet } from "./SelectionSheet.tsx";
import { TransferFocus } from "./TransferFocus.tsx";

/** The phone (iPhone or Android): status up top, the transfer when there is one, two big actions within thumb reach. */
export function PhoneScreen() {
  const state = useAppState();
  const jobs = useJobs();
  const [picked, setPicked] = useState<Picked[] | null>(null);
  const [dismissed, setDismissed] = useState<string | null>(null);
  const [, bump] = useState(0);
  const photos = useRef<HTMLInputElement>(null);
  const files = useRef<HTMLInputElement>(null);

  const reading = currentReading(jobs, state);
  const show = reading && reading.key !== dismissed && reading.state !== "cancelled";
  const moving = reading?.state === "running";
  useTick(250, Boolean(reading && !["complete", "cancelled"].includes(reading.state)));
  const online = state.conn === "online";
  const activeJob = reading?.job && !["complete", "cancelled"].includes(reading.job.state) ? reading.job : null;
  useShortcuts({ job: activeJob, onOpen: () => files.current?.click() });

  const unfinished = resumeRecords().filter((r) => r.direction === "to-host" && !jobs.some((j) => j.id === r.transferId));

  return (
    <div className="flex flex-col gap-16 pb-40">
      <section className="flex flex-col gap-10 pt-4" aria-live="polite">
        <Swap k={show ? "transfer" : "home"}>
          {show ? (
            <TransferFocus r={reading!} rtt={state.rtt} peer="your PC" perspective="guest" onDone={() => setDismissed(reading!.key)} />
          ) : (
            <div className="flex flex-col gap-4">
              <h1 className="t-display" style={{ fontSize: "clamp(2.25rem, 1.6rem + 3vw, 3rem)" }}>
                {online ? "Connected to your PC" : "Reconnecting…"}
              </h1>
              <p className="t-lead">
                {online ? (
                  <>
                    Pick photos or files. They land in <span style={{ color: "var(--text)" }}>{state.folderName ? `“${state.folderName}”` : "your chosen folder"}</span> on the PC.
                  </>
                ) : (
                  "Is SwiftDrop still open on the PC, and are you on the same Wi-Fi?"
                )}
              </p>
            </div>
          )}
        </Swap>

        <Connection
          state={online ? (moving ? "transferring" : "connected") : "connecting"}
          left={{ name: deviceLabel(), kind: "phone", live: true }}
          right={{ name: "PC", kind: "pc", live: online }}
          flow="right"
          speed={reading?.speed ?? 0}
          compact
          caption={
            <>
              <span className="dot" data-state={online ? "live" : "warn"} />
              {online ? (moving ? "Sending over Wi-Fi" : "Connected locally") : "Looking for your PC"}
            </>
          }
        />

        {unfinished.length > 0 && !show && (
          <div className="flex flex-col gap-2 py-4" style={{ boxShadow: "0 -1px 0 var(--hairline), 0 1px 0 var(--hairline)" }}>
            <p className="t-body" style={{ color: "var(--text)" }}>
              {unfinished[0]!.label} didn't finish
            </p>
            <p className="t-small">{formatBytes(unfinished[0]!.bytes)}. Pick the same items again and it continues where it stopped.</p>
            <button className="btn btn-ghost btn-sm self-start -ml-3" onClick={() => (forgetRecord(unfinished[0]!.transferId), bump((n) => n + 1))}>
              Forget it
            </button>
          </div>
        )}
      </section>

      <Offers perspective="guest" />
      <Recent perspective="guest" />
      {isIOS && <IosNotes />}
      {isAndroid && <AndroidNotes />}

      <div className="dock">
        <button className={`btn ${show && reading?.state !== "complete" ? "btn-secondary" : "btn-primary"} btn-lg w-full`} disabled={!online} onClick={() => photos.current?.click()}>
          <Images size={20} strokeWidth={1.75} /> Send photos
        </button>
        <button className="btn btn-secondary btn-lg !px-5" disabled={!online} onClick={() => files.current?.click()} aria-label="Send files">
          <FolderUp size={20} strokeWidth={1.75} /> Files
        </button>
      </div>

      <input ref={photos} type="file" accept="image/*,video/*" multiple hidden onChange={(e) => (setPicked(fromInput(e.target.files)), (e.target.value = ""))} />
      <input ref={files} type="file" multiple hidden onChange={(e) => (setPicked(fromInput(e.target.files)), (e.target.value = ""))} />

      {picked && picked.length > 0 && (
        <SelectionSheet
          picked={picked}
          target="your PC"
          onClose={() => setPicked(null)}
          onSend={(chosen) => {
            setPicked(null);
            setDismissed(null);
            send(chosen, "to-host");
          }}
        />
      )}
    </div>
  );
}

function IosNotes() {
  const [open, setOpen] = useState(false);
  return (
    <section>
      <button className="btn btn-ghost -ml-3" onClick={() => setOpen(!open)} aria-expanded={open}>
        How iPhone handles this
        <ChevronDown size={16} strokeWidth={1.75} style={{ transform: open ? "rotate(180deg)" : undefined, transition: "transform 240ms var(--ease-out)" }} />
      </button>
      {open && (
        <ul className="swap-enter mt-2 pl-5 flex flex-col gap-2 t-small" style={{ color: "var(--text-2)" }}>
          <li>Keep SwiftDrop on screen while it sends. iOS pauses web pages in the background; it picks up where it stopped when you return.</li>
          <li>The photo picker may convert HEIC to JPEG and compress video. For originals, tap Options → Current in the picker, or use Files.</li>
          <li>Files from your PC go to Files › Downloads. Photos and videos can also go straight to your library.</li>
        </ul>
      )}
    </section>
  );
}

function AndroidNotes() {
  const [open, setOpen] = useState(false);
  return (
    <section>
      <button className="btn btn-ghost -ml-3" onClick={() => setOpen(!open)} aria-expanded={open}>
        How Android handles this
        <ChevronDown size={16} strokeWidth={1.75} style={{ transform: open ? "rotate(180deg)" : undefined, transition: "transform 240ms var(--ease-out)" }} />
      </button>
      {open && (
        <ul className="swap-enter mt-2 pl-5 flex flex-col gap-2 t-small" style={{ color: "var(--text-2)" }}>
          <li>Keep SwiftDrop open while it sends. If Chrome goes to the background the transfer pauses and picks up where it stopped when you return.</li>
          <li>Send photos opens your gallery at original quality. Use Files for documents, or to pick from other apps.</li>
          <li>Files from your PC go to Downloads. Photos and videos saved there also show up in your gallery.</li>
        </ul>
      )}
    </section>
  );
}
