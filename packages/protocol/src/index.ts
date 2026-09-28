import { z } from "zod";

/**
 * SwiftDrop wire protocol, v1.
 *
 * Control plane: small JSON bodies validated with Zod on both ends.
 * Data plane:    raw binary request bodies (never base64, never JSON-wrapped).
 *
 *   PUT  /api/transfers/:tid/files/:fid/blocks/:start   body = contiguous blocks
 *   POST /api/transfers/:tid/batch                       body = batch frame (many small files)
 *
 * Files are addressed in fixed BLOCK_SIZE units. Requests carry 1..MAX_BLOCKS_PER_CHUNK
 * blocks, chosen adaptively by the sender, so resume state never depends on chunk size.
 */

export const PROTOCOL_VERSION = 1 as const;
export const BLOCK_SIZE = 1 << 20; // 1 MiB — unit of resume + integrity
export const MAX_BLOCKS_PER_CHUNK = 16; // 16 MiB max request body
export const SMALL_FILE_MAX = 512 * 1024; // files up to this size ride in batch frames
export const BATCH_TARGET_BYTES = 8 << 20;
export const BATCH_MAX_FILES = 512;
export const MAX_FILES_PER_TRANSFER = 100_000;

export const HEADERS = {
  /** base64url of concatenated per-block digests for the request body. */
  blockHashes: "x-sd-hashes",
  /** Server write-queue pressure 0..1 — a backpressure hint to the sender. */
  serverLoad: "x-sd-load",
  protocol: "x-sd-protocol",
} as const;

export const WS_SUBPROTOCOL = "swiftdrop.v1";
export const WS_AUTH_PREFIX = "auth.";

const id = z.string().regex(/^[A-Za-z0-9_-]{6,64}$/);

export const IntegritySchema = z.enum(["xxh64", "sha256"]);
export const ConflictPolicySchema = z.enum(["ask", "replace", "skip", "keep-both"]);
export type ConflictPolicy = z.infer<typeof ConflictPolicySchema>;
/** to-host: phone -> PC. to-guest: PC -> phone. to-peer: phone -> phone, direct (never via the PC). */
export const DirectionSchema = z.enum(["to-host", "to-guest", "to-peer"]);
export type Direction = z.infer<typeof DirectionSchema>;

export const FileEntrySchema = z.object({
  id,
  name: z.string().min(1).max(1024),
  relDir: z.string().max(4096).default(""),
  size: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  type: z.string().max(255).default(""),
  lastModified: z.number().int().nonnegative().default(0),
});
export type FileEntry = z.infer<typeof FileEntrySchema>;

export const CreateTransferSchema = z.object({
  protocol: z.literal(PROTOCOL_VERSION),
  transferId: id,
  direction: DirectionSchema,
  label: z.string().max(200).default(""),
  integrity: IntegritySchema.default("xxh64"),
  onConflict: ConflictPolicySchema.default("ask"),
  /** Per-file decisions from a previous "ask" round, keyed by file id. */
  decisions: z.record(id, z.enum(["replace", "skip", "keep-both"])).default({}),
  bench: z.boolean().default(false),
  files: z.array(FileEntrySchema).min(1).max(MAX_FILES_PER_TRANSFER),
});
export type CreateTransfer = z.input<typeof CreateTransferSchema>;

export const FileStateSchema = z.enum(["new", "partial", "complete", "skipped"]);
export type FileState = z.infer<typeof FileStateSchema>;

export const FileStatusSchema = z.object({
  id,
  state: FileStateSchema,
  /** base64 bitmap of received blocks when partial */
  received: z.string().optional(),
  finalName: z.string().optional(),
});
export type FileStatus = z.infer<typeof FileStatusSchema>;

export const TransferStatusSchema = z.object({
  transferId: id,
  blockSize: z.number().int().positive(),
  integrity: IntegritySchema,
  files: z.array(FileStatusSchema),
});
export type TransferStatus = z.infer<typeof TransferStatusSchema>;

export const ConflictSchema = z.object({
  id,
  name: z.string(),
  size: z.number(),
  existingSize: z.number(),
});
export type Conflict = z.infer<typeof ConflictSchema>;
export const ConflictResponseSchema = z.object({ conflicts: z.array(ConflictSchema) });

export const CompleteFileSchema = z.object({ root: z.string().regex(/^[0-9a-f]{16,64}$/) });

// ---------------------------------------------------------------------------
// Pairing

export const JoinRequestSchema = z.object({
  token: z.string().max(128).optional(),
  code: z.string().max(16).optional(),
  deviceName: z.string().min(1).max(64),
});

export const ApproveJoinSchema = z.object({ approve: z.boolean() });

export const PickLocalSchema = z.object({ mode: z.enum(["files", "folder"]) });
/** Host-only: offer files already on the PC, by absolute path (the picker's output). */
export const OfferLocalSchema = z.object({ paths: z.array(z.string().min(1).max(4096)).min(1).max(10_000) });

export const SettingsPatchSchema = z.object({
  destination: z.string().min(1).max(1024).optional(),
  maxFileSize: z.number().int().positive().optional(),
});

// ---------------------------------------------------------------------------
// Offers (PC -> iPhone)

export interface OfferFile {
  id: string;
  name: string;
  relDir: string;
  size: number;
  type: string;
}

export interface Offer {
  transferId: string;
  label: string;
  createdAt: number;
  totalBytes: number;
  files: OfferFile[];
}

// ---------------------------------------------------------------------------
// Server -> client events (WebSocket). Kept small; progress is throttled server-side.

export interface DeviceInfo {
  id: string;
  name: string;
  online: boolean;
  pairedAt: number;
}

export interface ProgressEvent {
  t: "progress";
  transferId: string;
  direction: Direction;
  label: string;
  device: string;
  filesDone: number;
  filesTotal: number;
  bytesDone: number;
  bytesTotal: number;
  state: "active" | "complete" | "cancelled";
}

export type ServerEvent =
  | { t: "hello"; role: "host" | "guest"; deviceId: string | null }
  | { t: "join-request"; requestId: string; deviceName: string; via: "qr" | "code" }
  | { t: "join-resolved"; requestId: string }
  | { t: "devices"; devices: DeviceInfo[] }
  | { t: "offers"; offers: Offer[] }
  | { t: "settings"; destination: string }
  | { t: "pong"; n: number }
  | ProgressEvent;

// ---------------------------------------------------------------------------
// Batch frame: [u32 LE headerLength][header JSON utf8][file bytes concatenated]

export const BatchHeaderSchema = z.object({
  files: z
    .array(z.object({ id, size: z.number().int().nonnegative(), hash: z.string() }))
    .min(1)
    .max(BATCH_MAX_FILES),
});
export type BatchHeader = z.infer<typeof BatchHeaderSchema>;

export function encodeBatchHeader(header: BatchHeader): Uint8Array<ArrayBuffer> {
  const json = new TextEncoder().encode(JSON.stringify(header));
  const out = new Uint8Array(4 + json.byteLength);
  new DataView(out.buffer).setUint32(0, json.byteLength, true);
  out.set(json, 4);
  return out;
}

export function decodeBatch(frame: Uint8Array): { header: BatchHeader; payload: Uint8Array } {
  if (frame.byteLength < 4) throw new ProtocolError("BAD_FRAME", "frame too short");
  const len = new DataView(frame.buffer, frame.byteOffset, 4).getUint32(0, true);
  if (len > 1 << 20 || 4 + len > frame.byteLength) throw new ProtocolError("BAD_FRAME", "bad header length");
  const header = BatchHeaderSchema.parse(JSON.parse(new TextDecoder().decode(frame.subarray(4, 4 + len))));
  const payload = frame.subarray(4 + len);
  const expected = header.files.reduce((s, f) => s + f.size, 0);
  if (expected !== payload.byteLength) throw new ProtocolError("BAD_FRAME", "payload size mismatch");
  return { header, payload };
}

// ---------------------------------------------------------------------------
// Errors. Codes travel on the wire; messages are what people read.

export const ERROR_CODES = [
  "NETWORK",
  "UNAUTHORIZED",
  "FORBIDDEN",
  "PAIRING_EXPIRED",
  "PAIRING_DENIED",
  "DECLINED",
  "RATE_LIMITED",
  "NOT_FOUND",
  "BAD_REQUEST",
  "BAD_FRAME",
  "INTEGRITY",
  "INCOMPLETE",
  "TOO_LARGE",
  "DISK_FULL",
  "DISK_WRITE",
  "SOURCE_CHANGED",
  "CANCELLED",
  "SERVER",
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

export const USER_MESSAGES: Record<ErrorCode, string> = {
  NETWORK: "Connection interrupted. Reconnecting…",
  UNAUTHORIZED: "This device isn't paired anymore. Scan the code on your PC again.",
  FORBIDDEN: "That action isn't allowed from this device.",
  PAIRING_EXPIRED: "That code expired. Ask for a fresh one on the PC.",
  PAIRING_DENIED: "The PC declined the connection.",
  DECLINED: "The other phone declined the files.",
  RATE_LIMITED: "Too many attempts. Wait a minute and try again.",
  NOT_FOUND: "That transfer no longer exists on the PC.",
  BAD_REQUEST: "Something about that request didn't look right. Try again.",
  BAD_FRAME: "Part of the transfer arrived damaged. Resending it.",
  INTEGRITY: "Part of a file arrived damaged. Resending it automatically.",
  INCOMPLETE: "Catching up with the PC…",
  TOO_LARGE: "That file is bigger than this PC accepts. Change the limit in settings.",
  DISK_FULL: "The PC's drive is full. Free up space or choose another folder.",
  DISK_WRITE: "Couldn't save the file. Choose another folder on the PC.",
  SOURCE_CHANGED: "That file changed on the PC after it was shared. Share it again from the PC.",
  CANCELLED: "Transfer cancelled.",
  SERVER: "The PC hit an unexpected problem. Try again.",
};

export class ProtocolError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  constructor(code: ErrorCode, detail?: string, status?: number) {
    super(detail ?? code);
    this.code = code;
    this.status = status ?? defaultStatus(code);
  }
  get userMessage(): string {
    return USER_MESSAGES[this.code];
  }
}

function defaultStatus(code: ErrorCode): number {
  switch (code) {
    case "UNAUTHORIZED":
      return 401;
    case "FORBIDDEN":
    case "PAIRING_DENIED":
    case "DECLINED":
      return 403;
    case "NOT_FOUND":
    case "PAIRING_EXPIRED":
      return 404;
    case "RATE_LIMITED":
      return 429;
    case "TOO_LARGE":
      return 413;
    case "INTEGRITY":
    case "BAD_FRAME":
      return 422;
    case "INCOMPLETE":
      return 409;
    case "DISK_FULL":
    case "DISK_WRITE":
    case "SERVER":
      return 500;
    case "CANCELLED":
    case "SOURCE_CHANGED":
      return 410;
    default:
      return 400;
  }
}

export function userMessageFor(code: string | undefined): string {
  return (code && (USER_MESSAGES as Record<string, string>)[code]) || USER_MESSAGES.SERVER;
}
