import type { SourceFile } from "@swiftdrop/transfer-engine";

export interface Picked {
  file: File;
  relDir: string;
}

/** Files from an <input>. Folder inputs carry webkitRelativePath. */
export function fromInput(list: FileList | null): Picked[] {
  if (!list) return [];
  return Array.from(list, (file) => {
    const rel = (file as File & { webkitRelativePath?: string }).webkitRelativePath ?? "";
    return { file, relDir: rel.includes("/") ? rel.slice(0, rel.lastIndexOf("/")) : "" };
  });
}

/** Files and whole folders dropped onto the page (Chrome/Edge/Firefox on Windows). */
export async function fromDataTransfer(dt: DataTransfer): Promise<Picked[]> {
  const entries: FileSystemEntry[] = [];
  const loose: File[] = [];
  for (const item of Array.from(dt.items)) {
    if (item.kind !== "file") continue;
    const entry = item.webkitGetAsEntry?.();
    if (entry) entries.push(entry);
    else {
      const f = item.getAsFile();
      if (f) loose.push(f);
    }
  }
  if (!entries.length) return Array.from(dt.files, (file) => ({ file, relDir: "" }));
  const out: Picked[] = loose.map((file) => ({ file, relDir: "" }));
  await Promise.all(entries.map((e) => walk(e, "", out)));
  return out;
}

async function walk(entry: FileSystemEntry, dir: string, out: Picked[]): Promise<void> {
  if (entry.isFile) {
    const file = await new Promise<File>((res, rej) => (entry as FileSystemFileEntry).file(res, rej));
    out.push({ file, relDir: dir });
    return;
  }
  if (!entry.isDirectory) return;
  const reader = (entry as FileSystemDirectoryEntry).createReader();
  const path = dir ? `${dir}/${entry.name}` : entry.name;
  // readEntries returns at most ~100 per call; keep asking until it returns nothing.
  for (;;) {
    const batch = await new Promise<FileSystemEntry[]>((res, rej) => reader.readEntries(res, rej));
    if (!batch.length) break;
    await Promise.all(batch.map((child) => walk(child, path, out)));
  }
}

export function fingerprint(p: { name: string; size: number; lastModified: number; relDir: string }): string {
  return `${p.relDir}/${p.name}|${p.size}|${Math.floor(p.lastModified / 1000)}`;
}

export function toSources(picked: Picked[], ids?: string[]): SourceFile[] {
  return picked.map((p, i) => ({
    id: ids?.[i] ?? `file_${i.toString(36).padStart(5, "0")}`,
    name: p.file.name || `file-${i}`,
    relDir: p.relDir,
    size: p.file.size,
    type: p.file.type,
    lastModified: p.file.lastModified || Date.now(),
    blob: p.file,
  }));
}

export type Kind = "image" | "video" | "audio" | "archive" | "document" | "other";

export function kindOf(name: string, type: string): Kind {
  if (type.startsWith("image/") || /\.(heic|heif|jpe?g|png|gif|webp|dng|raw|tiff?)$/i.test(name)) return "image";
  if (type.startsWith("video/") || /\.(mov|mp4|m4v|avi|mkv|hevc)$/i.test(name)) return "video";
  if (type.startsWith("audio/") || /\.(m4a|mp3|wav|aac|flac)$/i.test(name)) return "audio";
  if (/\.(zip|7z|rar|tar|gz)$/i.test(name)) return "archive";
  if (/\.(pdf|docx?|xlsx?|pptx?|txt|md|pages|numbers|key|csv)$/i.test(name)) return "document";
  return "other";
}

/** "248 photos · 12 videos", "Vacation", "report.pdf" */
export function describe(picked: Picked[]): string {
  if (picked.length === 1) return picked[0]!.file.name;
  const topDirs = new Set(picked.map((p) => p.relDir.split("/")[0] ?? ""));
  if (topDirs.size === 1 && [...topDirs][0]) return [...topDirs][0]!;
  let images = 0;
  let videos = 0;
  for (const p of picked) {
    const k = kindOf(p.file.name, p.file.type);
    if (k === "image") images++;
    else if (k === "video") videos++;
  }
  const others = picked.length - images - videos;
  const parts: string[] = [];
  if (images) parts.push(`${images} ${images === 1 ? "photo" : "photos"}`);
  if (videos) parts.push(`${videos} ${videos === 1 ? "video" : "videos"}`);
  if (others) parts.push(`${others} ${others === 1 ? "file" : "files"}`);
  return parts.join(" · ");
}
