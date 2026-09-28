import { useSyncExternalStore } from "react";
import type { Conflict, DeviceInfo, Offer, ProgressEvent } from "@swiftdrop/protocol";
import type { ConflictDecision } from "@swiftdrop/transfer-engine";

export type Conn = "connecting" | "online" | "offline";

export interface JoinRequestView {
  requestId: string;
  deviceName: string;
  via: "qr" | "code";
}

export interface PendingConflict {
  conflicts: Conflict[];
  resolve: (d: Record<string, ConflictDecision> | null) => void;
}

export interface AppState {
  role: "host" | "guest" | null;
  phase: "boot" | "join" | "ready";
  conn: Conn;
  rtt: number | null;
  devices: DeviceInfo[];
  joinRequests: JoinRequestView[];
  offers: Offer[];
  destination: string;
  /** Host only: PC files can be offered in place through a native dialog. */
  nativePick: boolean;
  /** Guest only: name of the PC folder files land in. */
  folderName: string | null;
  /** Transfers the PC is receiving (or the phone is downloading), from server events. */
  remote: Record<string, ProgressEvent & { at: number }>;
  conflict: PendingConflict | null;
  notice: { tone: "info" | "error"; text: string } | null;
}

type Listener = () => void;

function createStore<T extends object>(initial: T) {
  let state = initial;
  const listeners = new Set<Listener>();
  return {
    get: () => state,
    set(patch: Partial<T> | ((s: T) => Partial<T>)) {
      const next = typeof patch === "function" ? patch(state) : patch;
      state = { ...state, ...next };
      for (const l of listeners) l();
    },
    subscribe(l: Listener) {
      listeners.add(l);
      return () => listeners.delete(l);
    },
  };
}

export const app = createStore<AppState>({
  role: null,
  phase: "boot",
  conn: "connecting",
  rtt: null,
  devices: [],
  joinRequests: [],
  offers: [],
  destination: "",
  nativePick: false,
  folderName: null,
  remote: {},
  conflict: null,
  notice: null,
});

/** Select a slice; components re-render only when that slice's identity changes. */
export function useApp<S>(select: (s: AppState) => S): S {
  return useSyncExternalStore(app.subscribe, () => select(app.get()));
}

let noticeTimer: ReturnType<typeof setTimeout> | undefined;
export function notify(text: string, tone: "info" | "error" = "info") {
  app.set({ notice: { tone, text } });
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => app.set({ notice: null }), tone === "error" ? 7000 : 4000);
}
