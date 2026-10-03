import { useSyncExternalStore } from "react";
import { storage } from "../lib/env.ts";

/** Finished phone-to-phone transfers on this device, newest first. Local only. */
export interface HistoryItem {
  id: string;
  label: string;
  dir: "sent" | "received";
  peer: string;
  files: number;
  bytes: number;
  seconds: number;
  at: number;
  kind: "image" | "video" | "mixed" | "file";
}

const KEY = "sd.p2p.history";
let items: HistoryItem[] = storage.get<HistoryItem[]>(KEY) ?? [];
const listeners = new Set<() => void>();

export function addHistory(item: HistoryItem) {
  if (items.some((i) => i.id === item.id && i.dir === item.dir)) return;
  items = [item, ...items].slice(0, 30);
  storage.set(KEY, items);
  for (const l of listeners) l();
}

export function useHistory(): HistoryItem[] {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => items,
  );
}
