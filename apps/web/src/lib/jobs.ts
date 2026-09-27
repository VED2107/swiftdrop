import type { Direction } from "@swiftdrop/protocol";
import {
  DESKTOP_CONTROLLER,
  HttpTransport,
  MOBILE_CONTROLLER,
  TransferJob,
  TransferQueue,
  type ConflictDecision,
} from "@swiftdrop/transfer-engine";
import { getToken } from "./api.ts";
import { isIOS, isMobile, storage } from "./env.ts";
import { describe, fingerprint, toSources, type Picked } from "./files.ts";
import { onRtt } from "./socket.ts";
import { addRecent } from "./recent.ts";
import { kindOf } from "./files.ts";
import { app } from "./store.ts";

export const queue = new TransferQueue();

// ---------------------------------------------------------------------------
// Resume records. A page reload loses File objects (browsers never persist them),
// so we remember what was being sent; picking the same files again resumes it.

interface ResumeRecord {
  transferId: string;
  direction: Direction;
  label: string;
  createdAt: number;
  bytes: number;
  files: Array<{ id: string; fp: string }>;
}
const RESUME_KEY = "sd.resume";

export function resumeRecords(): ResumeRecord[] {
  return storage.get<ResumeRecord[]>(RESUME_KEY) ?? [];
}
function saveRecords(r: ResumeRecord[]) {
  storage.set(RESUME_KEY, r.slice(-10));
}
export function forgetRecord(transferId: string) {
  saveRecords(resumeRecords().filter((r) => r.transferId !== transferId));
}

function matchRecord(picked: Picked[], direction: Direction): { record: ResumeRecord; ids: string[] } | null {
  const fps = picked.map((p) => fingerprint({ name: p.file.name, size: p.file.size, lastModified: p.file.lastModified, relDir: p.relDir }));
  for (const record of resumeRecords()) {
    if (record.direction !== direction || record.files.length !== fps.length) continue;
    const byFp = new Map(record.files.map((f) => [f.fp, f.id]));
    const ids = fps.map((fp) => byFp.get(fp));
    if (ids.every((id): id is string => Boolean(id))) return { record, ids };
  }
  return null;
}

// ---------------------------------------------------------------------------

export function send(picked: Picked[], direction: Direction): TransferJob | null {
  if (!picked.length) return null;
  const match = matchRecord(picked, direction);
  const files = toSources(picked, match?.ids);
  const job = new TransferJob({
    transport: new HttpTransport({ baseUrl: location.origin, ...(getToken() ? { token: getToken()! } : {}) }),
    files,
    direction,
    label: match?.record.label ?? describe(picked),
    ...(match ? { transferId: match.record.transferId } : {}),
    controller: isIOS || isMobile ? MOBILE_CONTROLLER : DESKTOP_CONTROLLER,
    onConflict: direction === "to-host" ? "ask" : "keep-both",
    resolveConflicts: (conflicts) =>
      new Promise<Record<string, ConflictDecision> | null>((resolve) => {
        app.set({
          conflict: {
            conflicts,
            resolve: (d) => {
              app.set({ conflict: null });
              resolve(d);
            },
          },
        });
      }),
  });

  if (!match) {
    saveRecords([
      ...resumeRecords(),
      {
        transferId: job.id,
        direction,
        label: job.label,
        createdAt: Date.now(),
        bytes: job.bytesTotal,
        files: files.map((f, i) => ({ id: f.id, fp: fingerprint({ ...files[i]!, lastModified: picked[i]!.file.lastModified }) })),
      },
    ]);
  }
  job.onChange((j) => {
    if (j.state === "complete" || j.state === "cancelled") forgetRecord(j.id);
    if (j.state === "complete") {
      const snap = j.snapshot();
      addRecent({
        id: j.id,
        label: j.label,
        flow: direction === "to-host" ? "to-pc" : "to-phone",
        files: snap.filesTotal,
        bytes: snap.bytesTotal,
        seconds: snap.elapsedSeconds,
        at: Date.now(),
        kinds: countKinds(files),
      });
      const avg = snap.average;
      // Only trust averages from transfers long enough to mean something.
      if (avg > 0 && j.bytesTotal > 50e6) storage.set("sd.lastSpeed", avg);
    }
  });
  queue.add(job);
  return job;
}

onRtt((ms) => {
  for (const j of queue.list()) if (j.state === "running") j.setRtt(ms);
});

// ---------------------------------------------------------------------------
// Keep the iPhone screen awake while sending: iOS suspends a backgrounded or locked
// Safari tab, which would stall the transfer. (It resumes on return either way.)

let wakeLock: WakeLockSentinel | null = null;
async function syncWakeLock() {
  const busy = queue.list().some((j) => ["preparing", "running", "reconnecting"].includes(j.state));
  try {
    if (busy && !wakeLock && "wakeLock" in navigator && document.visibilityState === "visible") {
      wakeLock = await navigator.wakeLock.request("screen");
      wakeLock.addEventListener("release", () => (wakeLock = null));
    } else if (!busy && wakeLock) {
      await wakeLock.release();
      wakeLock = null;
    }
  } catch {
    /* not supported or denied: transfers still work, the screen may just lock */
  }
}
queue.subscribe(() => void syncWakeLock());
document.addEventListener("visibilitychange", () => void syncWakeLock());

function countKinds(files: ReadonlyArray<{ name: string; type: string }>) {
  const k = { images: 0, videos: 0, other: 0 };
  for (const f of files) {
    const t = kindOf(f.name, f.type);
    if (t === "image") k.images++;
    else if (t === "video") k.videos++;
    else k.other++;
  }
  return k;
}
