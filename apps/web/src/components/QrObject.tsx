import { RefreshCw } from "lucide-react";
import type { Pairing } from "../lib/api.ts";
import { QrCode } from "./QrCode.tsx";

/**
 * The pairing code as a physical object: a bright card on the dark field.
 * idle → lifts on hover · connecting → settles and rings (the phone has scanned it)
 * · expired → blurs with a refresh action.
 */
export function QrObject({ pairing, state, onRefresh }: { pairing: Pairing | null; state: "idle" | "connecting" | "expired"; onRefresh: () => void }) {
  return (
    <div className="qr-object" data-state={state}>
      {pairing?.qr ? (
        <QrCode size={pairing.qr.size} bits={pairing.qr.bits} label="Pairing code. Scan it with your phone’s camera." />
      ) : (
        <div className="w-full h-full rounded-2xl" style={{ background: "oklch(0.9 0.004 90)" }} aria-busy="true" />
      )}
      {state === "expired" && (
        <button className="btn btn-secondary btn-sm absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2" onClick={onRefresh} style={{ background: "var(--bg)" }}>
          <RefreshCw size={14} strokeWidth={1.75} /> New code
        </button>
      )}
    </div>
  );
}
