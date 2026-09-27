import { useSyncExternalStore } from "react";
import { storage } from "./env.ts";

/** Finished transfers, newest first. Small, local, per device. */
export interface RecentItem {
  id: string;
  label: string;
  flow: "to-pc" | "to-phone";
  files: number;
  bytes: number;
  seconds: number;
  at: number;
  kinds: { images: number; videos: number; other: number };
}

const KEY = "sd.recent";
let items: RecentItem[] = storage.get<RecentItem[]>(KEY) ?? [];
const listeners = new Set<() => void>();

export function addRecent(item: RecentItem) {
  if (items.some((i) => i.id === item.id)) return;
  items = [item, ...items].slice(0, 40);
  storage.set(KEY, items);
  for (const l of listeners) l();
}

export function clearRecent() {
  items = [];
  storage.set(KEY, items);
  for (const l of listeners) l();
}

export function useRecent(): RecentItem[] {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => items,
  );
}

export function timeAgo(at: number): string {
  const s = Math.round((Date.now() - at) / 1000);
  if (s < 45) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  return new Date(at).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/** "~18 seconds remaining", "~2 min remaining" — humans read durations, not clocks. */
export function humanEta(seconds: number): string {
  if (!Number.isFinite(seconds)) return "Estimating…";
  if (seconds < 1.5) return "Almost done";
  if (seconds < 60) return `About ${Math.max(2, Math.round(seconds))} seconds left`;
  if (seconds < 3600) {
    const m = Math.round(seconds / 60);
    return `About ${m} ${m === 1 ? "minute" : "minutes"} left`;
  }
  const h = Math.floor(seconds / 3600);
  const m = Math.round((seconds % 3600) / 60);
  return `About ${h} h ${m} min left`;
}

export function humanDuration(seconds: number): string {
  if (seconds < 1) return "under a second";
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  if (m < 60) return `${m}m ${s}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}
