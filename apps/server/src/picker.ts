import { spawn } from "node:child_process";
import { lstat, readdir } from "node:fs/promises";
import { basename, extname, isAbsolute, join, resolve } from "node:path";
import { MAX_FILES_PER_TRANSFER, ProtocolError } from "@swiftdrop/protocol";

/**
 * PC-side file sources for PC -> phone. The web page can't hand the server a file path,
 * so staging used to mean a browser upload over loopback (~40 MB/s in Chromium). Picking
 * with a native dialog gives the server the path: the phone downloads straight from the
 * original file, nothing is copied.
 */

export type PickMode = "files" | "folder";

export interface LocalSource {
  path: string;
  name: string;
  /** folder segments relative to what was picked (a picked folder is its own first segment) */
  relDir: string[];
  size: number;
  lastModified: number;
  type: string;
}

/** Shell clutter Explorer creates on its own; nobody means to send these. */
const JUNK = new Set(["desktop.ini", "thumbs.db", ".ds_store"]);

/** Stats picked paths; folders are walked (symlinks and junctions are not followed). */
export async function expandPaths(paths: string[]): Promise<LocalSource[]> {
  const out: LocalSource[] = [];
  const add = (path: string, relDir: string[], size: number, mtimeMs: number) => {
    if (out.length >= MAX_FILES_PER_TRANSFER) throw new ProtocolError("TOO_LARGE", "too many files");
    const name = basename(path);
    out.push({ path, name, relDir, size, lastModified: Math.max(0, Math.round(mtimeMs)), type: mimeFor(name) });
  };
  const walk = async (dir: string, relDir: string[]) => {
    const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) await walk(full, [...relDir, e.name]);
      else if (e.isFile() && !JUNK.has(e.name.toLowerCase())) {
        const st = await lstat(full).catch(() => null);
        if (st?.isFile()) add(full, relDir, st.size, st.mtimeMs);
      }
    }
  };
  for (const raw of paths) {
    if (!isAbsolute(raw)) throw new ProtocolError("BAD_REQUEST", "path must be absolute");
    const path = resolve(raw);
    const st = await lstat(path).catch(() => null);
    if (!st) throw new ProtocolError("NOT_FOUND", "picked file is gone");
    if (st.isDirectory()) await walk(path, [basename(path)]);
    else if (st.isFile()) add(path, [], st.size, st.mtimeMs);
  }
  return out;
}

const MIME: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".heic": "image/heic",
  ".heif": "image/heif",
  ".avif": "image/avif",
  ".bmp": "image/bmp",
  ".tif": "image/tiff",
  ".tiff": "image/tiff",
  ".dng": "image/x-adobe-dng",
  ".mp4": "video/mp4",
  ".m4v": "video/x-m4v",
  ".mov": "video/quicktime",
  ".webm": "video/webm",
  ".mkv": "video/x-matroska",
  ".avi": "video/x-msvideo",
  ".mp3": "audio/mpeg",
  ".m4a": "audio/mp4",
  ".aac": "audio/aac",
  ".wav": "audio/wav",
  ".flac": "audio/flac",
  ".ogg": "audio/ogg",
  ".pdf": "application/pdf",
  ".zip": "application/zip",
  ".txt": "text/plain",
};

export function mimeFor(name: string): string {
  return MIME[extname(name).toLowerCase()] ?? "";
}

/** Native Windows dialog, run as the logged-in user sitting at this PC. Null when cancelled. */
export function pickDialog(mode: PickMode | "destination", current = ""): Promise<string[] | null> {
  if (process.platform !== "win32") return Promise.reject(new ProtocolError("BAD_REQUEST", "native picker is Windows-only"));
  const common = [
    "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8",
    "Add-Type -AssemblyName System.Windows.Forms",
    "$owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }",
  ];
  const body =
    mode === "files"
      ? [
          "$d = New-Object System.Windows.Forms.OpenFileDialog",
          "$d.Title = 'Choose files to send to your phone'",
          "$d.Multiselect = $true",
          "$d.DereferenceLinks = $true",
          "if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write(($d.FileNames -join \"`n\")) }",
        ]
      : [
          "$d = New-Object System.Windows.Forms.FolderBrowserDialog",
          mode === "folder" ? "$d.Description = 'Choose a folder to send to your phone'" : "$d.Description = 'Choose where SwiftDrop saves received files'",
          "$d.UseDescriptionForTitle = $true",
          `$d.ShowNewFolderButton = $${mode === "destination"}`,
          "if ($env:SD_CURRENT -and (Test-Path -LiteralPath $env:SD_CURRENT)) { $d.SelectedPath = $env:SD_CURRENT }",
          "if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Out.Write($d.SelectedPath) }",
        ];
  const script = [...common, ...body].join("; ");
  return new Promise((resolvePromise) => {
    const child = spawn("powershell.exe", ["-NoProfile", "-STA", "-NonInteractive", "-Command", script], {
      env: { ...process.env, SD_CURRENT: current },
      windowsHide: false,
    });
    let out = "";
    child.stdout.on("data", (d: Buffer) => (out += d.toString("utf8")));
    const timer = setTimeout(() => child.kill(), 5 * 60_000);
    child.on("close", () => {
      clearTimeout(timer);
      const paths = out
        .split(/\r?\n/)
        .map((p) => p.trim())
        .filter(Boolean);
      resolvePromise(paths.length ? paths : null);
    });
    child.on("error", () => resolvePromise(null));
  });
}
