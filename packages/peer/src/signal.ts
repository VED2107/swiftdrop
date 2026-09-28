import { base64UrlToBytes, bytesToBase64Url } from "@swiftdrop/crypto";
import { z } from "zod";

/**
 * Signaling payload: exactly what WebRTC needs to connect, plus a display name. It travels
 * as text (a QR code today). Compressed so a full SDP with its candidates fits one QR.
 */

export const SignalPayloadSchema = z.object({
  v: z.literal(1),
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
  let bytes: Uint8Array;
  try {
    const raw = base64UrlToBytes(s.slice(1));
    bytes = s[0] === DEFLATE ? await pipe(raw, new DecompressionStream("deflate-raw")) : raw;
    return SignalPayloadSchema.parse(JSON.parse(new TextDecoder().decode(bytes)));
  } catch {
    throw new Error("That code couldn't be read. Try scanning it again.");
  }
}

/** Accepts the bare signal or a link carrying it in the fragment (`…#o=` / `…#a=`). */
export function extractSignal(text: string): string | null {
  const t = text.trim();
  const m = /[#&?](?:o|a)=([DP][A-Za-z0-9_-]+)/.exec(t);
  if (m) return m[1]!;
  return /^[DP][A-Za-z0-9_-]+$/.test(t) ? t : null;
}

async function pipe(data: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const out = new Blob([data as Uint8Array<ArrayBuffer>]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}
