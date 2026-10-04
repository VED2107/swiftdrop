import { formatBytes } from "@swiftdrop/shared";
import { ArrowUp, ChevronDown, FolderUp } from "lucide-react";
import { useRef, useState } from "react";
import { deviceLabel, isAndroid, isIOS } from "../lib/env.ts";
import { fromInput, type Picked } from "../lib/files.ts";
import { forgetRecord, resumeRecords, send } from "../lib/jobs.ts";
import { markPicked, markPickerOpened } from "../lib/latency.ts";
import { currentReading, useAppState, useJobs, useTick } from "../lib/reading.ts";
import { useShortcuts } from "../lib/shortcuts.ts";
import { Swap } from "../ui/Swap.tsx";
import { Rail } from "./Rail.tsx";
import { LatencyCard } from "./LatencyCard.tsx";
import { Offers } from "./Offers.tsx";
import { Recent } from "./Recent.tsx";
import { SelectionSheet } from "./SelectionSheet.tsx";
import { TransferFocus } from "./TransferFocus.tsx";

const DEBUG = typeof location !== "undefined" && new URLSearchParams(location.search).has("debug");

/** The phone (iPhone or Android): status up top, the transfer when there is one, two big actions within thumb reach. */
export function PhoneScreen() {
  const state = useAppState();
  const jobs = useJobs();
  const [picked, setPicked] = useState<Picked[] | null>(null);
  const [dismissed, setDismissed] = useState<string | null>(null);
  const [, bump] = useState(0);
  const [burst, setBurst] = useState(0);
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
    <div className="flex flex-col gap-12 pb-16">
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

        {!show && (
          <div className="console">
            <Rail state={online ? "linked" : "idle"} left={deviceLabel()} right="PC" burst={burst} />
            <p className="console-status">
              <span className="dot" data-state={online ? "live" : "warn"} />
              {online ? "Connected locally" : "Looking for your PC"}
            </p>
          </div>
        )}

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

      {/* The one big red Send key opens the photo picker; files go through the quieter key. */}
      <section className="send-deck" aria-label="Send">
        <button
          className="send-key"
          disabled={!online}
          onClick={() => (setBurst((n) => n + 1), markPickerOpened(), photos.current?.click())}
          aria-label="Send photos and videos"
        >
          <span className="send-key-face">
            <ArrowUp size={30} strokeWidth={2.25} aria-hidden />
            <span>Send photos</span>
          </span>
        </button>
        <p className="send-caption">Photos and videos, as originals</p>
        <button className="btn btn-secondary btn-lg" disabled={!online} onClick={() => (setBurst((n) => n + 1), markPickerOpened(), files.current?.click())}>
          <FolderUp size={18} strokeWidth={1.75} aria-hidden /> Send files
        </button>
      </section>

      {DEBUG && <LatencyCard />}
      <Offers perspective="guest" />
      <Recent perspective="guest" />
      {isIOS && <IosNotes />}
      {isAndroid && <AndroidNotes />}

      <input ref={photos} type="file" accept="image/*,video/*" multiple hidden onChange={(e) => (markPicked(), setPicked(fromInput(e.target.files)), (e.target.value = ""))} />
      <input ref={files} type="file" multiple hidden onChange={(e) => (markPicked(), setPicked(fromInput(e.target.files)), (e.target.value = ""))} />

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
          <li>Before sending starts, iOS copies what you picked out of the Photos library (and downloads it first if it lives in iCloud). Big videos take longest. If the picker converts videos, tap Options at the top of the picker and choose Current to skip the conversion. Sending starts the moment iOS hands the files over.</li>
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
