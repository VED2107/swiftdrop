const UNITS = ["B", "KB", "MB", "GB", "TB"] as const;

/** Decimal units (1 MB = 10^6 B), matching how Windows Explorer rounds and how Wi-Fi is marketed. */
export function formatBytes(bytes: number, digits = 1): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  let i = 0;
  let v = bytes;
  while (v >= 1000 && i < UNITS.length - 1) {
    v /= 1000;
    i++;
  }
  return `${v.toFixed(i === 0 || v >= 100 ? 0 : digits)} ${UNITS[i]}`;
}

export function formatRate(bytesPerSecond: number): string {
  return `${formatBytes(bytesPerSecond)}/s`;
}

export function formatDuration(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "--:--";
  const s = Math.round(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
  return `${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

const intl = new Intl.NumberFormat("en-US");
export function formatCount(n: number): string {
  return intl.format(n);
}
