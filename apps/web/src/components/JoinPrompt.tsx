import { Smartphone } from "lucide-react";
import { Api } from "../lib/api.ts";
import { notify, useApp } from "../lib/store.ts";

/** A new device asking to connect while another is already paired: surfaces wherever you are. */
export function JoinPrompt() {
  const req = useApp((s) => s.joinRequests[0]);
  if (!req) return null;
  return (
    <div className="join-prompt" role="alertdialog" aria-labelledby="join-prompt-title">
      <div className="row-thumb" style={{ width: 40, height: 40 }}>
        <Smartphone size={18} strokeWidth={1.5} />
      </div>
      <div className="min-w-0">
        <div id="join-prompt-title" style={{ fontWeight: 520 }}>
          {req.deviceName} wants to connect
        </div>
        <div className="t-small">{req.returning ? "Paired before. Allowing it replaces its old entry." : "Only allow a device you're holding."}</div>
      </div>
      <div className="flex gap-1">
        <button className="btn btn-ghost btn-sm" onClick={() => void Api.approve(req.requestId, false).catch(() => undefined)}>
          Decline
        </button>
        <button className="btn btn-primary btn-sm" onClick={() => void Api.approve(req.requestId, true).catch((e: Error) => notify(e.message, "error"))}>
          Allow
        </button>
      </div>
    </div>
  );
}
