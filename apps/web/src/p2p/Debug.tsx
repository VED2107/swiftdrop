import { describePath, type DataChannelTransport, type PathInfo, type PeerSession, type ReceivedTransfer } from "@swiftdrop/peer";
import type { TransferJob } from "@swiftdrop/transfer-engine";
import { useEffect, useRef, useState } from "react";
import type { OpfsSinkFactory } from "./opfs.ts";

/**
 * Internal performance panel (`?debug=1`, never shown otherwise). Rates are deltas over the
 * panel's own 1 s clock, so they read what actually moved, not a per-chunk spike.
 */

export interface DebugSources {
  flow: string;
  session: PeerSession | null;
  link: DataChannelTransport | null;
  job: TransferJob | null;
  sinks: OpfsSinkFactory | null;
  receiving: ReceivedTransfer | null;
  marks: { picked: number; linked: number; jobStart: number };
}

type Row = [label: string, value: string];

export function DebugPanel({ sources }: { sources: () => DebugSources }) {
  const [rows, setRows] = useState<Array<[string, Row[]]>>([]);
  const prev = useRef({ t: performance.now(), sent: 0, recv: 0, stored: 0, storeMs: 0, read: 0, hash: 0, net: 0 });
  const path = useRef<PathInfo | null>(null);
  const [open, setOpen] = useState(true);
  // The parent passes a fresh closure every repaint; the clock below must not restart.
  const src = useRef(sources);
  src.current = sources;

  useEffect(() => {
    const tick = async () => {
      const s = src.current();
      if (s.session) path.current = await describePath(s.session.pc).catch(() => path.current);
      const now = performance.now();
      const p = prev.current;
      const dt = Math.max(0.001, (now - p.t) / 1000);
      const ls = s.link?.stats;
      const tel = s.job?.telemetry();
      const st = s.sinks?.stats;
      const mbs = (bytes: number) => `${(bytes / 1e6 / dt).toFixed(1)} MB/s`;
      const ms = (v: number | null | undefined) => (v === null || v === undefined ? "–" : `${Math.round(v)} ms`);
      const rate = (bytes: number, msSpent: number) => (msSpent > 0 ? `${(bytes / 1e3 / msSpent).toFixed(1)} MB/s` : "–");

      const conn: Row[] = [
        ["flow", s.flow],
        ["pc", s.session ? `${s.session.pc.connectionState} / ice ${s.session.pc.iceConnectionState}` : "–"],
        ["path", path.current ? `${path.current.kind} (${path.current.local?.type ?? "?"} ↔ ${path.current.remote?.type ?? "?"}, ${path.current.local?.protocol ?? ""})` : "–"],
        ["rtt", path.current?.rttMs != null ? `${path.current.rttMs} ms` : "–"],
        ["frame", s.link ? `${(s.link.chunkBytes / 1024).toFixed(0)} KiB` : "–"],
      ];
      const sender: Row[] = s.job
        ? [
            ["channel send", ls ? mbs(ls.bytesSent - p.sent) : "–"],
            ["bufferedAmount", s.link ? `${(s.link.getBufferedAmount() / 1024).toFixed(0)} KiB (peak ${((ls?.peakBuffered ?? 0) / 1048576).toFixed(1)} MiB)` : "–"],
            ["stalls", ls ? `${ls.stalls} · ${Math.round(ls.stallMs)} ms waiting` : "–"],
            ["file read", tel ? rate(tel.payloadBytes, tel.stages.readMs) : "–"],
            ["hashing", tel ? rate(tel.payloadBytes, tel.stages.hashMs) : "–"],
            ["streams × chunk", (() => {
              const sn = s.job.snapshot();
              return `${sn.streams} × ${(sn.chunkBytes / 1048576).toFixed(0)} MiB (${sn.inflight} in flight, ${sn.lastDecision ?? "–"})`;
            })()],
            ["ack latency p50/p95", tel ? `${ms(tel.latencyP50)} / ${ms(tel.latencyP95)}` : "–"],
            ["stage ms read/hash/frame/net", tel ? `${Math.round(tel.stages.readMs)}/${Math.round(tel.stages.hashMs)}/${Math.round(tel.stages.frameMs)}/${Math.round(tel.stages.networkMs)} (${tel.requests} req)` : "–"],
          ]
        : [];
      const receiver: Row[] = s.receiving || (ls && ls.bytesReceived > 0)
        ? [
            ["channel receive", ls ? mbs(ls.bytesReceived - p.recv) : "–"],
            ["storage", st ? `${mbs(st.bytes - p.stored)} · ${rate(st.bytes, st.busyMs)} while busy` : "–"],
            ["writes", st ? `${st.writes}` : "–"],
          ]
        : [];
      const memory: Row[] = tel ? [["in flight", `${(tel.inflightBytes / 1048576).toFixed(1)} MiB (peak ${(tel.peakInflightBytes / 1048576).toFixed(1)})`]] : [];
      const m = s.marks;
      const timing: Row[] = tel
        ? [
            ["picker → link", m.picked && m.linked ? ms(Math.max(0, m.linked - m.picked)) : "–"],
            ["job start → first send", ms(tel.startToFirstSendMs)],
            ["accept → first send", tel.startToFirstSendMs != null ? ms(tel.startToFirstSendMs - tel.prepareMs) : "–"],
            ["job start → first ack", ms(tel.startToFirstAckMs)],
            ["first file done", ms(tel.startToFirstFileMs)],
            ["accept wait (prepare)", ms(tel.prepareMs)],
          ]
        : [];
      setRows(
        [
          ["Connection", conn],
          ["Sender", sender],
          ["Receiver", receiver],
          ["Memory", memory],
          ["Timing", timing],
        ].filter(([, r]) => (r as Row[]).length) as Array<[string, Row[]]>,
      );
      prev.current = { t: now, sent: ls?.bytesSent ?? 0, recv: ls?.bytesReceived ?? 0, stored: st?.bytes ?? 0, storeMs: st?.busyMs ?? 0, read: 0, hash: 0, net: 0 };
    };
    const t = setInterval(() => void tick(), 1000);
    return () => clearInterval(t);
  }, []);

  return (
    <aside className="p2p-debug" data-testid="debug" aria-label="Performance panel">
      <button className="p2p-debug-toggle" onClick={() => setOpen((o) => !o)}>
        {open ? "Hide" : "Perf"}
      </button>
      {open &&
        rows.map(([title, r]) => (
          <section key={title}>
            <h3>{title}</h3>
            <dl>
              {r.map(([k, v]) => (
                <div key={k}>
                  <dt>{k}</dt>
                  <dd className="num">{v}</dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
    </aside>
  );
}
