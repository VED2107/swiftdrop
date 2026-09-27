const ua = typeof navigator === "undefined" ? "" : navigator.userAgent;

/** iPadOS reports as Mac; touch points give it away. */
export const isIOS = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && typeof navigator !== "undefined" && navigator.maxTouchPoints > 1);
export const isAndroid = /Android/.test(ua);
export const isMobile = isIOS || isAndroid;

/** Short label for this device in the UI: "iPhone", "iPad", "Android", or "This device". */
export function deviceLabel(): string {
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua) || (isIOS && /Macintosh/.test(ua))) return "iPad";
  if (isAndroid) return "Android";
  return "This device";
}

export function deviceName(): string {
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua) || (isIOS && /Macintosh/.test(ua))) return "iPad";
  if (/Android/.test(ua)) return "Android phone";
  if (/Windows/.test(ua)) return "Windows PC";
  if (/Macintosh/.test(ua)) return "Mac";
  return "Device";
}

export const prefersReducedMotion = () => typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;

export const canShareFiles = (files: File[]) => {
  try {
    return typeof navigator.canShare === "function" && navigator.canShare({ files });
  } catch {
    return false;
  }
};

/** Storage can throw in private mode; never let that break the app. */
export const storage = {
  get<T>(key: string): T | null {
    try {
      const v = localStorage.getItem(key);
      return v ? (JSON.parse(v) as T) : null;
    } catch {
      return null;
    }
  },
  set(key: string, value: unknown) {
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch {
      /* quota or private mode */
    }
  },
  remove(key: string) {
    try {
      localStorage.removeItem(key);
    } catch {
      /* ignore */
    }
  },
};
