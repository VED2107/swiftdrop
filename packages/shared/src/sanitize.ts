/**
 * Filename and path sanitization. Everything a remote peer sends is treated as hostile:
 * names are normalized, stripped of separators/control/bidi characters, Windows reserved
 * names are escaped, and relative paths are reduced to safe segments (no "..", no roots).
 */

const INVALID_CHARS = /[\u0000-\u001f\u007f<>:"/\\|?*‎‏‪-‮⁦-⁩]/g;
const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\..*)?$/i;
const MAX_NAME_LENGTH = 180;
const MAX_SEGMENTS = 32;

export function extname(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot) : "";
}

export function sanitizeFileName(input: string, fallback = "file"): string {
  let name = input.normalize("NFC").replace(INVALID_CHARS, "_").trim();
  name = name.replace(/[. ]+$/g, "");
  if (name === "" || /^\.+$/.test(name)) name = fallback;
  if (WINDOWS_RESERVED.test(name)) name = `_${name}`;
  if (name.length > MAX_NAME_LENGTH) {
    const ext = extname(name).slice(0, 16);
    name = name.slice(0, MAX_NAME_LENGTH - ext.length) + ext;
  }
  return name;
}

/** Splits a client-supplied relative directory path into safe segments. Never returns "..". */
export function sanitizeRelativeDir(input: string | undefined | null): string[] {
  if (!input) return [];
  const segments: string[] = [];
  for (const raw of input.split(/[\\/]+/)) {
    const trimmed = raw.trim();
    if (trimmed === "" || trimmed === "." || trimmed === "..") continue;
    segments.push(sanitizeFileName(trimmed, "folder"));
    if (segments.length >= MAX_SEGMENTS) break;
  }
  return segments;
}

/** "IMG_001.jpg" -> "IMG_001 (2).jpg" */
export function numberedName(name: string, n: number): string {
  const ext = extname(name);
  const base = ext ? name.slice(0, -ext.length) : name;
  return `${base} (${n})${ext}`;
}
