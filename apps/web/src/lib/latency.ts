import type { TransferJob } from "@swiftdrop/transfer-engine";

/**
 * Time-to-first-byte for a send, measured on the phone. All marks use performance.now(),
 * the same clock the engine uses, so they line up with job.telemetry().
 *
 * The OS photo picker's own work (iOS copying originals out of the library, downloading
 * iCloud originals) happens before the page gets the files and cannot be separated from
 * the time a person spends choosing; `tapToPickedMs` holds both. Everything after the
 * picker returns is SwiftDrop's and is broken down stage by stage.
 */
export interface LatencyReport {
  transferId: string;
  files: number;
  bytes: number;
  /** "Send photos" tap -> picker returned files (OS export + the person choosing) */
  tapToPickedMs: number | null;
  /** picker returned -> Send tapped in the review sheet (the person reviewing) */
  pickedToSendMs: number | null;
  /** Send tapped -> transfer screen rendered */
  sendToUiMs: number | null;
  /** Send tapped -> engine started (queue wait) */
  sendToStartMs: number;
  hasherMs: number;
  /** manifest round trip to the receiver */
  createMs: number;
  /** Send tapped -> first file bytes read into memory */
  sendToFirstReadMs: number | null;
  /** Send tapped -> first request body handed to the network: first byte leaves the phone */
  sendToFirstByteMs: number | null;
  /** Send tapped -> receiver confirmed the first bytes written: first byte arrived at the PC */
  sendToFirstAckMs: number | null;
  /** Send tapped -> first whole file verified on the receiver */
  sendToFirstFileMs: number | null;
}

const marks = { photosTap: 0, picked: 0 };
const pending = new Map<string, { send: number; ui: number; tap: number; picked: number }>();
const reports: LatencyReport[] = [];
const listeners = new Set<() => void>();

declare global {
  interface Window {
    __sdLatency?: LatencyReport[];
  }
}
if (typeof window !== "undefined") window.__sdLatency = reports;

export function markPickerOpened() {
  marks.photosTap = performance.now();
  marks.picked = 0;
}

export function markPicked() {
  marks.picked = performance.now();
}

/** Call when the send is handed to the engine; reports itself once the first file lands. */
export function trackSend(job: TransferJob) {
  const rec = { send: performance.now(), ui: 0, tap: marks.photosTap, picked: marks.picked };
  pending.set(job.id, rec);
  marks.photosTap = marks.picked = 0;
  const off = job.onChange(() => maybeReport(job));
  // A small single file can finish between two state changes; poll briefly as a backstop.
  const timer = setInterval(() => maybeReport(job) && (clearInterval(timer), off()), 100);
  void job.done.then(() => (maybeReport(job, true), clearInterval(timer), off()));
}

/** The transfer screen calls this once it is on screen for a job. */
export function markTransferUi(transferId: string) {
  const rec = pending.get(transferId);
  if (rec && !rec.ui) rec.ui = performance.now();
}

export function latencyReports(): readonly LatencyReport[] {
  return reports;
}

export function onLatency(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function maybeReport(job: TransferJob, final = false): boolean {
  const rec = pending.get(job.id);
  if (!rec) return true;
  const t = job.telemetry();
  if (!t.startedAt) return final; // never started (cancelled while queued): nothing to report
  if (t.startToFirstFileMs === null && !final) return false;
  pending.delete(job.id);
  const rel = (v: number | null) => (v === null ? null : round(t.startedAt + v - rec.send));
  const report: LatencyReport = {
    transferId: job.id,
    files: job.files.length,
    bytes: job.bytesTotal,
    tapToPickedMs: rec.tap && rec.picked ? round(rec.picked - rec.tap) : null,
    pickedToSendMs: rec.picked ? round(rec.send - rec.picked) : null,
    sendToUiMs: rec.ui ? round(rec.ui - rec.send) : null,
    sendToStartMs: round(t.startedAt - rec.send),
    hasherMs: round(t.hasherMs),
    createMs: round(t.createMs),
    sendToFirstReadMs: rel(t.startToFirstReadMs),
    sendToFirstByteMs: rel(t.startToFirstSendMs),
    sendToFirstAckMs: rel(t.startToFirstAckMs),
    sendToFirstFileMs: rel(t.startToFirstFileMs),
  };
  reports.push(report);
  if (reports.length > 20) reports.shift();
  console.info(`[sd-latency] ${JSON.stringify(report)}`);
  for (const fn of listeners) fn();
  return true;
}

const round = (v: number) => Math.round(v * 10) / 10;
