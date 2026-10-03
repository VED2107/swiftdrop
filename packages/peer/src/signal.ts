import { base64UrlToBytes, bytesToBase64Url } from "@swiftdrop/crypto";
import { z } from "zod";

/**
 * Signaling payload: exactly what WebRTC needs to connect, plus a display name. It travels
 * as text: in the pairing QR, sealed in a rendezvous mailbox message (rendezvous.ts),
 * or in a reply QR when there's no internet. Compressed so a full SDP with its candidates
 * fits one QR. Never carries file data.
 *
 * v2 = data-plane wire format v2 (channel.ts). A v1 page can't talk to a v2 page, so the
 * version is checked here, where a clear message can still be shown.
 */

export const SIGNAL_VERSION = 2;

export const SignalPayloadSchema = z.object({
  v: z.literal(SIGNAL_VERSION),
  type: z.enum(["offer", "answer"]),
  sdp: z.string().min(1).max(16_384),
  sid: z.string().regex(/^[0-9a-f]{8,32}$/),
  name: z.string().max(40),
});
export type SignalPayload = z.infer<typeof SignalPayloadSchema>;

const DEFLATE = "D";
const PLAIN = "P";

export async function encodeSignal(p: SignalPayload): Promise<string> {
  const json = new TextEncoder().encode(JSON.stringify(SignalPayloadSchema.parse(p)));
  if (typeof CompressionStream === "undefined") return PLAIN + bytesToBase64Url(json);
  return DEFLATE + bytesToBase64Url(await pipe(json, new CompressionStream("deflate-raw")));
}

export async function decodeSignal(text: string): Promise<SignalPayload> {
  const s = extractSignal(text);
  if (!s) throw new Error("That code isn't from SwiftDrop.");
  let json: { v?: unknown };
  try {
    const raw = base64UrlToBytes(s.slice(1));
    const bytes = s[0] === DEFLATE ? await pipe(raw, new DecompressionStream("deflate-raw")) : raw;
    json = JSON.parse(new TextDecoder().decode(bytes)) as { v?: unknown };
  } catch {
    throw new Error("That code couldn't be read. Try scanning it again.");
  }
  if (json.v !== SIGNAL_VERSION) throw new Error("The other phone has a different version of SwiftDrop open. Reload the page on both phones.");
  const parsed = SignalPayloadSchema.safeParse(json);
  if (!parsed.success) throw new Error("That code couldn't be read. Try scanning it again.");
  return parsed.data;
}

/** Accepts the bare signal or a link carrying it in the fragment (`…#o=` pairing code, `…#a=` reply). */
export function extractSignal(text: string): string | null {
  const t = text.trim();
  const m = /[#&?](?:r|o|a)=([DP][A-Za-z0-9_-]+)/.exec(t);
  if (m) return m[1]!;
  return /^[DP][A-Za-z0-9_-]+$/.test(t) ? t : null;
}

/** What the pairing QR carries: the offer, and the mailbox secret the answer goes through. */
export interface PairCode {
  offer: string;
  /** base64url mailbox secret; null on codes made without a rendezvous (offline) */
  key: string | null;
}

/** `…#o=<offer>&k=<secret>`: opened by the Camera app, or read by the in-app scanner. */
export function pairLink(base: string, code: PairCode): string {
  return `${base}#o=${code.offer}${code.key ? `&k=${code.key}` : ""}`;
}

export function parsePairCode(text: string): PairCode | null {
  const t = text.trim();
  const offer = /[#&?][or]=([DP][A-Za-z0-9_-]+)/.exec(t)?.[1];
  if (!offer) return null;
  return { offer, key: /[#&?]k=([A-Za-z0-9_-]{22,64})/.exec(t)?.[1] ?? null };
}

async function pipe(data: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const out = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}
