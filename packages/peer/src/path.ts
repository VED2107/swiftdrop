/**
 * What network path did ICE actually pick? "Connected over WebRTC" does not by itself
 * mean direct, and direct does not mean same network. Read the selected candidate pair
 * and only claim what the addresses prove.
 */

export type CandidateType = "host" | "srflx" | "prflx" | "relay" | "unknown";

export interface CandidateInfo {
  type: CandidateType;
  address: string;
  protocol: string;
}

export interface PathInfo {
  /** "local": not relayed and both ends are private/link-local/mDNS addresses. */
  kind: "local" | "p2p" | "relayed" | "unknown";
  local: CandidateInfo | null;
  remote: CandidateInfo | null;
  /** Current round trip on the selected pair, ms. */
  rttMs: number | null;
}

export function classifyPath(local: CandidateInfo | null, remote: CandidateInfo | null, rttMs: number | null = null): PathInfo {
  if (!local || !remote) return { kind: "unknown", local, remote, rttMs };
  if (local.type === "relay" || remote.type === "relay") return { kind: "relayed", local, remote, rttMs };
  const local2 = isLocalAddress(local.address) && isLocalAddress(remote.address);
  // Global IPv6 on both ends is still the same LAN when both sit in one /64.
  const sameV6Lan = local.type === "host" && remote.type !== "srflx" && sameSlash64(local.address, remote.address);
  return { kind: local2 || sameV6Lan ? "local" : "p2p", local, remote, rttMs };
}

function sameSlash64(a: string, b: string): boolean {
  const prefix = (x: string) => {
    const s = x.trim().toLowerCase().replace(/^\[|\]$/g, "");
    if (!s.includes(":") || s.includes(".")) return null;
    const [head, tail = ""] = s.split("::");
    const h = head ? head.split(":") : [];
    const t = tail ? tail.split(":") : [];
    const groups = [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill("0"), ...t];
    return groups.slice(0, 4).map((g) => parseInt(g || "0", 16)).join(":");
  };
  const pa = prefix(a);
  return pa !== null && pa === prefix(b);
}

/** RFC 1918, link-local, loopback, IPv6 ULA/link-local, and mDNS names (host candidates only exist on-link). */
export function isLocalAddress(addr: string): boolean {
  const a = addr.trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (!a) return false;
  if (a.endsWith(".local")) return true;
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(a.replace(/^::ffff:/, ""));
  if (v4) {
    const [p, q] = [Number(v4[1]), Number(v4[2])];
    return p === 10 || p === 127 || (p === 172 && q >= 16 && q <= 31) || (p === 192 && q === 168) || (p === 169 && q === 254);
  }
  if (a.includes(":")) return a === "::1" || /^f[cd][0-9a-f]{2}:/.test(a) || /^fe[89ab][0-9a-f]:/.test(a);
  return false;
}

interface StatLike {
  id: string;
  type: string;
  [k: string]: unknown;
}

/** Selected pair from an RTCStatsReport-shaped map (browser differences handled). */
export function pathFromStats(stats: Iterable<StatLike>): PathInfo {
  const all = new Map<string, StatLike>();
  for (const s of stats) all.set(s.id, s);
  let pair: StatLike | undefined;
  for (const s of all.values()) {
    if (s.type === "transport" && typeof s.selectedCandidatePairId === "string") pair = all.get(s.selectedCandidatePairId);
  }
  if (!pair) {
    for (const s of all.values()) {
      if (s.type !== "candidate-pair" || s.state !== "succeeded") continue;
      // Safari/Firefox mark the chosen pair with `selected`/`nominated` instead of transport.selectedCandidatePairId.
      if (s.selected === true || s.nominated === true || !pair) pair = s;
    }
  }
  if (!pair) return classifyPath(null, null);
  const cand = (id: unknown): CandidateInfo | null => {
    const c = typeof id === "string" ? all.get(id) : undefined;
    if (!c) return null;
    const type = String(c.candidateType ?? "unknown");
    return {
      type: (["host", "srflx", "prflx", "relay"].includes(type) ? type : "unknown") as CandidateType,
      address: String(c.address ?? c.ip ?? ""),
      protocol: String(c.protocol ?? ""),
    };
  };
  const rtt = typeof pair.currentRoundTripTime === "number" ? Math.round(pair.currentRoundTripTime * 1000) : null;
  return classifyPath(cand(pair.localCandidateId), cand(pair.remoteCandidateId), rtt);
}

export async function describePath(pc: RTCPeerConnection): Promise<PathInfo> {
  const report = await pc.getStats();
  return pathFromStats(report.values() as Iterable<StatLike>);
}

export function pathLabel(p: PathInfo): { title: string; detail: string } {
  const via = p.local && p.remote ? `${p.local.protocol.toUpperCase() || "?"} · ${p.local.type} ↔ ${p.remote.type}` : "";
  switch (p.kind) {
    case "local":
      return { title: "Direct · Local network", detail: via };
    case "p2p":
      return { title: "Direct · P2P", detail: `Network path: ${p.local!.address || "?"} ↔ ${p.remote!.address || "?"} (${via})` };
    case "relayed":
      return { title: "Connected · Relayed", detail: via };
    default:
      return { title: "Connected", detail: "Checking the network path…" };
  }
}
