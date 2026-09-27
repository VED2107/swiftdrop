import { formatBytes, formatCount } from "@swiftdrop/shared";
import { ArrowDownLeft, ArrowUpRight, Check, FolderOpen } from "lucide-react";
import { Api } from "../lib/api.ts";
import { notify } from "../lib/store.ts";
import { timeAgo, useRecent } from "../lib/recent.ts";
import { useTick } from "../lib/reading.ts";

/** Finished transfers as quiet rows. An empty history is an invitation, not a box. */
export function Recent({ perspective }: { perspective: "host" | "guest" }) {
  const items = useRecent();
  useTick(30_000, items.length > 0);
  return (
    <section id="transfers" aria-labelledby="recent-title" className="flex flex-col gap-3 scroll-mt-24">
      <h2 id="recent-title" className="t-section">
        Recent transfers
      </h2>
      {items.length === 0 ? (
        <div className="py-6">
          <p className="t-body" style={{ color: "var(--text-2)" }}>
            Nothing yet.
          </p>
          <p className="t-small mt-1">Transfer something between your devices and it shows up here.</p>
        </div>
      ) : (
        <div>
          {items.slice(0, 8).map((it, i) => {
            const incoming = perspective === "host" ? it.flow === "to-pc" : it.flow === "to-phone";
            const Icon = incoming ? ArrowDownLeft : ArrowUpRight;
            return (
              <div key={it.id} className="row rise" style={{ "--i": i } as React.CSSProperties}>
                <div className="row-thumb">
                  <Icon size={17} strokeWidth={1.5} />
                </div>
                <div className="min-w-0">
                  <div className="truncate" style={{ fontWeight: 500, letterSpacing: "-0.01em" }}>
                    {it.label}
                  </div>
                  <div className="t-small num">
                    {incoming ? "Received" : "Sent"} · {formatCount(it.files)} {it.files === 1 ? "file" : "files"} · {timeAgo(it.at)}
                  </div>
                </div>
                <div className="flex items-center gap-3">
                  {perspective === "host" && incoming && (
                    <button className="btn btn-ghost btn-sm reveal" onClick={() => void Api.reveal(it.id).catch((e: Error) => notify(e.message, "error"))}>
                      <FolderOpen size={15} strokeWidth={1.75} /> Show in folder
                    </button>
                  )}
                  <span className="t-small num" style={{ color: "var(--text-2)" }}>
                    {formatBytes(it.bytes)}
                  </span>
                  <Check size={16} strokeWidth={2} style={{ color: "var(--success)" }} aria-label="Complete" />
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
