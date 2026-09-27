import { useEffect, useRef } from "react";
import type { TransferJob } from "@swiftdrop/transfer-engine";
import { notify } from "./store.ts";

const typing = (t: EventTarget | null) => t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName));

/**
 * Ctrl/Cmd+O choose files · Space pause/resume · Esc twice cancels the active transfer
 * (cancel is destructive, so one stray Esc only arms it).
 */
export function useShortcuts({ job, onOpen }: { job: TransferJob | null; onOpen: (() => void) | null }) {
  const armed = useRef(0);
  const ref = useRef({ job, onOpen });
  ref.current = { job, onOpen };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const { job, onOpen } = ref.current;
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "o" && onOpen) {
        e.preventDefault();
        onOpen();
        return;
      }
      if (typing(e.target) || document.querySelector(".scrim")) return;
      if (e.key === " " && job) {
        if (job.state === "running" || job.state === "reconnecting") {
          e.preventDefault();
          job.pause();
        } else if (job.state === "paused") {
          e.preventDefault();
          job.resume();
        }
        return;
      }
      if (e.key === "Escape" && job && !["complete", "cancelled"].includes(job.state)) {
        const now = Date.now();
        if (now - armed.current < 2000) {
          armed.current = 0;
          void job.cancel();
          notify("Transfer cancelled.");
        } else {
          armed.current = now;
          notify("Press Esc again to cancel the transfer.");
        }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
}
