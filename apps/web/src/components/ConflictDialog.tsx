import { formatBytes, formatCount } from "@swiftdrop/shared";
import type { ConflictDecision } from "@swiftdrop/transfer-engine";
import { useApp } from "../lib/store.ts";
import { Sheet } from "../ui/Sheet.tsx";

/** Name clashes on the PC. One decision covers them all — nobody wants 400 prompts. */
export function ConflictDialog() {
  const pending = useApp((s) => s.conflict);
  if (!pending) return null;
  const { conflicts, resolve } = pending;
  const decide = (d: ConflictDecision) => resolve(Object.fromEntries(conflicts.map((c) => [c.id, d])));
  const same = conflicts.filter((c) => c.size === c.existingSize).length;

  return (
    <Sheet
      title={conflicts.length === 1 ? "Already on your PC" : `${formatCount(conflicts.length)} files are already on your PC`}
      onClose={() => resolve(null)}
      footer={
        <>
          <button className="btn btn-ghost mr-auto" onClick={() => resolve(null)}>
            Cancel
          </button>
          <button className="btn btn-secondary" onClick={() => decide("replace")}>
            Replace
          </button>
          <button className="btn btn-secondary" onClick={() => decide("keep-both")}>
            Keep both
          </button>
          <button className="btn btn-primary" autoFocus onClick={() => decide("skip")}>
            Skip {conflicts.length === 1 ? "it" : "them"}
          </button>
        </>
      }
    >
      <p className="t-body mb-4">
        {same === conflicts.length ? "Same names and sizes, so they're most likely identical." : "Some share a name but differ in size."}
      </p>
      <div>
        {conflicts.slice(0, 60).map((c) => (
          <div key={c.id} className="flex justify-between gap-4 py-2.5" style={{ boxShadow: "0 1px 0 var(--hairline)" }}>
            <span className="truncate t-small" style={{ color: "var(--text)" }}>
              {c.name}
            </span>
            <span className="t-micro num shrink-0">{c.size === c.existingSize ? formatBytes(c.size) : `${formatBytes(c.size)} · PC has ${formatBytes(c.existingSize)}`}</span>
          </div>
        ))}
        {conflicts.length > 60 && <p className="t-small pt-3">and {formatCount(conflicts.length - 60)} more</p>}
      </div>
    </Sheet>
  );
}
