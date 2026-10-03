import {
  ConflictResponseSchema,
  HEADERS,
  PROTOCOL_VERSION,
  TransferStatusSchema,
  type Conflict,
  type CreateTransfer,
  type ErrorCode,
  type TransferStatus,
  userMessageFor,
} from "@swiftdrop/protocol";

export class TransportError extends Error {
  readonly code: ErrorCode;
  readonly status: number;
  constructor(code: ErrorCode, status = 0, detail?: string) {
    super(detail ?? code);
    this.code = code;
    this.status = status;
  }
  get userMessage(): string {
    return userMessageFor(this.code);
  }
}

export type CreateResult = { status: TransferStatus } | { conflicts: Conflict[] };

/** What the engine needs from the network. HTTP today; a native TCP/QUIC transport later. */
export interface Transport {
  create(req: CreateTransfer): Promise<CreateResult>;
  status(transferId: string): Promise<TransferStatus>;
  putBlocks(transferId: string, fileId: string, startBlock: number, body: Uint8Array<ArrayBuffer>, hashes: string, signal: AbortSignal): Promise<{ load: number }>;
  putBatch(transferId: string, body: Uint8Array<ArrayBuffer>, signal: AbortSignal): Promise<{ load: number }>;
  complete(transferId: string, fileId: string, root: string): Promise<{ finalName: string }>;
  cancel(transferId: string): Promise<void>;
  ping(signal?: AbortSignal): Promise<void>;
}

export interface HttpTransportOptions {
  baseUrl: string;
  token?: string;
  fetch?: typeof fetch;
}

export class HttpTransport implements Transport {
  private readonly base: string;
  private readonly token: string | undefined;
  private readonly fetchImpl: typeof fetch;

  constructor(opts: HttpTransportOptions) {
    this.base = opts.baseUrl.replace(/\/$/, "");
    this.token = opts.token;
    this.fetchImpl = opts.fetch ?? globalThis.fetch.bind(globalThis);
  }

  async create(req: CreateTransfer): Promise<CreateResult> {
    const res = await this.request("POST", "/api/transfers", JSON.stringify(req), { json: true, allow409: true });
    const body: unknown = await res.json();
    if (res.status === 409) return ConflictResponseSchema.parse(body);
    return { status: TransferStatusSchema.parse(body) };
  }

  async status(transferId: string): Promise<TransferStatus> {
    const res = await this.request("GET", `/api/transfers/${transferId}`);
    return TransferStatusSchema.parse(await res.json());
  }

  async putBlocks(transferId: string, fileId: string, startBlock: number, body: Uint8Array<ArrayBuffer>, hashes: string, signal: AbortSignal) {
    // Blob, not the typed array: Chromium streams Blob bodies from its blob store but pushes
    // ArrayBufferView bodies through a slow path — measured 350 MB/s vs 20 MB/s on loopback.
    const res = await this.request("PUT", `/api/transfers/${transferId}/files/${fileId}/blocks/${startBlock}`, new Blob([body]), {
      headers: { [HEADERS.blockHashes]: hashes, "content-type": "application/octet-stream" },
      signal,
    });
    return { load: readLoad(res) };
  }

  async putBatch(transferId: string, body: Uint8Array<ArrayBuffer>, signal: AbortSignal) {
    // Blob for the same reason as putBlocks: Chromium's fast upload path.
    const res = await this.request("POST", `/api/transfers/${transferId}/batch`, new Blob([body]), {
      headers: { "content-type": "application/octet-stream" },
      signal,
    });
    return { load: readLoad(res) };
  }

  async complete(transferId: string, fileId: string, root: string) {
    const res = await this.request("POST", `/api/transfers/${transferId}/files/${fileId}/complete`, JSON.stringify({ root }), { json: true });
    return (await res.json()) as { finalName: string };
  }

  async cancel(transferId: string): Promise<void> {
    await this.request("DELETE", `/api/transfers/${transferId}`);
  }

  async ping(signal?: AbortSignal): Promise<void> {
    await this.request("GET", "/api/ping", undefined, signal ? { signal } : {});
  }

  private async request(
    method: string,
    path: string,
    body?: BodyInit,
    opts: { json?: boolean; headers?: Record<string, string>; signal?: AbortSignal; allow409?: boolean } = {},
  ): Promise<Response> {
    const headers: Record<string, string> = { [HEADERS.protocol]: String(PROTOCOL_VERSION), ...opts.headers };
    if (this.token) headers.authorization = `Bearer ${this.token}`;
    if (opts.json) headers["content-type"] = "application/json";
    let res: Response;
    try {
      res = await this.fetchImpl(this.base + path, { method, body: body ?? null, headers, signal: opts.signal ?? null, cache: "no-store" });
    } catch (err) {
      if (opts.signal?.aborted) throw new TransportError("CANCELLED");
      throw new TransportError("NETWORK", 0, err instanceof Error ? err.message : String(err));
    }
    if (res.ok || (opts.allow409 && res.status === 409)) return res;
    let code: ErrorCode = res.status === 401 ? "UNAUTHORIZED" : res.status === 404 ? "NOT_FOUND" : "SERVER";
    try {
      const payload = (await res.json()) as { code?: ErrorCode };
      if (payload.code) code = payload.code;
    } catch {
      /* non-JSON error body */
    }
    throw new TransportError(code, res.status);
  }
}

function readLoad(res: Response): number {
  const v = Number(res.headers.get(HEADERS.serverLoad));
  return Number.isFinite(v) ? v : 0;
}
