import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { Health, JobSnapshot, TransferJob } from "@swiftdrop/transfer-engine";
import { queue } from "./jobs.ts";
import { remoteRate } from "./socket.ts";
import { app, type AppState } from "./store.ts";

/** Everything the readout shows, whether we're the sender or only watching the receiver. */
export interface Reading {
  key: string;
  title: string;
  flow: "to-pc" | "to-phone";
  state: JobSnapshot["state"] | "active" | "cancelled";
  bytesDone: number;
  bytesTotal: number;
  filesDone: number;
  filesTotal: number;
  speed: number;
  average: number;
  peak: number;
  eta: number;
  streams: number | null;
  chunkBytes: number | null;
  filesPerSecond: number | null;
  retries: number | null;
  health: Health;
  message: string | null;
  job: TransferJob | null;
}

/** Re-render on a fixed clock while `active`. The engine never pushes per-chunk updates. */
export function useTick(ms: number, active: boolean): number {
  const [n, setN] = useState(0);
  useEffect(() => {
    if (!active) return;
    const id = setInterval(() => setN((x) => x + 1), ms);
    return () => clearInterval(id);
  }, [ms, active]);
  return n;
}

const snapQueue = () => queue.list();
let cachedList: readonly TransferJob[] = [];
let cachedVersion = 0;
let version = 0;
queue.subscribe(() => version++);
export function useJobs(): readonly TransferJob[] {
  return useSyncExternalStore(queue.subscribe.bind(queue), () => {
    if (cachedVersion !== version) {
      cachedVersion = version;
      cachedList = [...snapQueue()];
    }
    return cachedList;
  });
}

export function fromJob(job: TransferJob, role: AppState["role"]): Reading {
  const s = job.snapshot();
  return {
    key: job.id,
    title: job.label,
    flow: (job.direction === "to-host") === (role !== "host") ? "to-pc" : "to-phone",
    state: s.state,
    bytesDone: s.bytesDone,
    bytesTotal: s.bytesTotal,
    filesDone: s.filesDone + s.filesSkipped,
    filesTotal: s.filesTotal,
    speed: s.speed,
    average: s.average,
    peak: s.peak,
    eta: s.etaSeconds,
    streams: s.streams,
    chunkBytes: s.chunkBytes,
    filesPerSecond: s.filesPerSecond,
    retries: s.retries,
    health: s.health,
    message: s.message,
    job,
  };
}

export function fromRemote(e: AppState["remote"][string]): Reading {
  const r = remoteRate(e.transferId);
  const remaining = e.bytesTotal - e.bytesDone;
  const basis = r.speed > 0 ? r.speed * 0.7 + r.average * 0.3 : r.average;
  const stale = e.state === "active" && Date.now() - e.at > 6000;
  return {
    key: e.transferId,
    title: e.label || "Incoming",
    flow: e.direction === "to-host" ? "to-pc" : "to-phone",
    state: e.state === "active" ? (stale ? "reconnecting" : "running") : e.state,
    bytesDone: e.bytesDone,
    bytesTotal: e.bytesTotal,
    filesDone: e.filesDone,
    filesTotal: e.filesTotal,
    speed: e.state === "active" ? r.speed : 0,
    average: r.average,
    peak: r.peak,
    eta: remaining <= 0 ? 0 : basis > 0 ? remaining / basis : Infinity,
    streams: null,
    chunkBytes: null,
    filesPerSecond: null,
    retries: null,
    health: stale ? "offline" : "good",
    message: stale ? `Waiting for ${e.device}…` : null,
    job: null,
  };
}

/** The one transfer the station readout should show right now. */
export function currentReading(jobs: readonly TransferJob[], state: AppState): Reading | null {
  const live = jobs.find((j) => ["preparing", "awaiting-decision", "running", "reconnecting"].includes(j.state));
  if (live) return fromJob(live, state.role);
  const remotes = Object.values(state.remote).sort((a, b) => b.at - a.at);
  const activeRemote = remotes.find((r) => r.state === "active");
  if (activeRemote) return fromRemote(activeRemote);
  const paused = jobs.find((j) => j.state === "paused" || j.state === "failed");
  if (paused) return fromJob(paused, state.role);
  const lastJob = [...jobs].reverse().find((j) => j.state === "complete");
  const lastRemote = remotes[0];
  if (lastRemote && (!lastJob || lastRemote.at > Date.now() - 60_000)) return fromRemote(lastRemote);
  return lastJob ? fromJob(lastJob, state.role) : null;
}

export const useAppState = () => useSyncExternalStore(app.subscribe, app.get);

/** True for a moment right after a transfer lands: drives the coupling's arrival flash. */
export function useArrival(r: Reading | null): boolean {
  const [flash, setFlash] = useState(false);
  const seen = useRef<string | null>(null);
  const done = r?.state === "complete" ? r.key : null;
  useEffect(() => {
    if (!done || seen.current === done) return;
    seen.current = done;
    setFlash(true);
    const t = setTimeout(() => setFlash(false), 950);
    return () => clearTimeout(t);
  }, [done]);
  return flash;
}
