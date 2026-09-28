import { userMessageFor, type DeviceInfo, type Offer } from "@swiftdrop/protocol";
import { storage } from "./env.ts";

const TOKEN_KEY = "sd.token";

export function getToken(): string | null {
  return storage.get<string>(TOKEN_KEY);
}
export function setToken(t: string | null) {
  if (t) storage.set(TOKEN_KEY, t);
  else storage.remove(TOKEN_KEY);
}

export class ApiError extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
  ) {
    super(userMessageFor(code));
  }
}

export async function api<T>(path: string, init: RequestInit & { json?: unknown } = {}): Promise<T> {
  const headers: Record<string, string> = { ...(init.headers as Record<string, string>) };
  const token = getToken();
  if (token) headers.authorization = `Bearer ${token}`;
  let body = init.body;
  if (init.json !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(init.json);
  }
  let res: Response;
  try {
    res = await fetch(path, { ...init, body: body ?? null, headers, cache: "no-store" });
  } catch {
    throw new ApiError("NETWORK", 0);
  }
  if (!res.ok) {
    let code = res.status === 401 ? "UNAUTHORIZED" : "SERVER";
    try {
      code = ((await res.json()) as { code?: string }).code ?? code;
    } catch {
      /* non-JSON */
    }
    throw new ApiError(code, res.status);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

export interface Info {
  role: "host" | "guest" | null;
  deviceId: string | null;
  deviceName: string | null;
  folderName: string | null;
  version: string;
}

export interface Pairing {
  code: string;
  expiresAt: number;
  url: string | null;
  manualUrl: string | null;
  address: string | null;
  addresses: Array<{ address: string; interfaceName: string; virtual: boolean }>;
  qr: { size: number; bits: string } | null;
}

export interface HostSettings {
  destination: string;
  maxFileSize: number;
  platform: string;
  /** The server can open a native file dialog and serve picks in place (no upload). */
  nativePick: boolean;
}

export const Api = {
  info: () => api<Info>("/api/info"),
  pairing: (address?: string, rotate = false) => {
    const q = new URLSearchParams();
    if (address) q.set("address", address);
    if (rotate) q.set("rotate", "1");
    return api<Pairing>(`/api/host/pairing?${q}`);
  },
  join: (body: { token?: string; code?: string; deviceName: string; installId?: string }) => api<{ requestId: string }>("/api/join", { method: "POST", json: body }),
  pollJoin: (id: string) => api<{ status: "pending" | "approved" | "denied"; token?: string }>(`/api/join/${id}`),
  approve: (id: string, approve: boolean) => api(`/api/host/joins/${id}`, { method: "POST", json: { approve } }),
  renameDevice: (id: string, name: string) => api<DeviceInfo>(`/api/host/devices/${id}`, { method: "PATCH", json: { name } }),
  renameSelf: (name: string) => api<DeviceInfo>("/api/device", { method: "PATCH", json: { name } }),
  forgetDevice: (id: string) => api(`/api/host/devices/${id}`, { method: "DELETE" }),
  devices: () => api<{ devices: DeviceInfo[] }>("/api/host/devices"),
  settings: () => api<HostSettings>("/api/host/settings"),
  chooseFolder: () => api<{ destination: string; changed: boolean }>("/api/host/choose-folder", { method: "POST" }),
  openFolder: () => api("/api/host/open-folder", { method: "POST" }),
  reveal: (transferId: string) => api<{ path: string }>(`/api/host/reveal/${transferId}`, { method: "POST" }),
  setDestination: (destination: string) => api<HostSettings>("/api/host/settings", { method: "PATCH", json: { destination } }),
  offers: () => api<{ offers: Offer[] }>("/api/offers"),
  ticket: (tid: string) => api<{ ticket: string }>(`/api/offers/${tid}/ticket`, { method: "POST" }),
  pickOffer: (mode: "files" | "folder") => api<{ offer: Offer | null }>("/api/host/offers/pick", { method: "POST", json: { mode } }),
  removeOffer: (tid: string) => api(`/api/offers/${tid}`, { method: "DELETE" }),
  stats: () => api<{ cpuUserMs: number; cpuSystemMs: number; rss: number; writeLoad: number }>("/api/stats"),
};
