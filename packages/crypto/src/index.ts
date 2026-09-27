import { createSHA256, createXXHash64, type IHasher } from "hash-wasm";

/**
 * Hashing and token helpers shared by browser and server.
 *
 * Why hash-wasm instead of crypto.subtle: the iPhone reaches the PC over plain
 * http://192.168.x.x, which is not a secure context, so crypto.subtle is undefined
 * in Safari there. WebAssembly works everywhere and xxh64 runs at several GB/s,
 * so integrity checks never become the bottleneck. SHA-256 stays available for
 * users who want a cryptographic digest.
 */

export type HashAlgo = "xxh64" | "sha256";
export const HASH_LENGTH: Record<HashAlgo, number> = { xxh64: 8, sha256: 32 };

export interface BlockHasher {
  readonly algo: HashAlgo;
  /** Hash `data` in `blockSize` slices; returns concatenated digests. Synchronous: safe to share. */
  hashBlocks(data: Uint8Array, blockSize: number): Uint8Array;
  /** Digest of a digest list — the per-file root. */
  root(blockHashes: Uint8Array): string;
}

const hasherCache = new Map<HashAlgo, Promise<IHasher>>();

function loadHasher(algo: HashAlgo): Promise<IHasher> {
  let p = hasherCache.get(algo);
  if (!p) {
    p = algo === "sha256" ? createSHA256() : createXXHash64();
    hasherCache.set(algo, p);
  }
  return p;
}

export async function createBlockHasher(algo: HashAlgo): Promise<BlockHasher> {
  const h = await loadHasher(algo);
  const len = HASH_LENGTH[algo];
  return {
    algo,
    hashBlocks(data, blockSize) {
      const count = Math.max(1, Math.ceil(data.byteLength / blockSize));
      const out = new Uint8Array(count * len);
      for (let i = 0; i < count; i++) {
        h.init();
        h.update(data.subarray(i * blockSize, Math.min(data.byteLength, (i + 1) * blockSize)));
        out.set(h.digest("binary"), i * len);
      }
      return out;
    },
    root(blockHashes) {
      h.init();
      h.update(blockHashes);
      return h.digest("hex");
    },
  };
}

// ---------------------------------------------------------------------------
// Random identifiers. crypto.getRandomValues works in insecure contexts too.

const B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

export function randomBytes(n: number): Uint8Array {
  const out = new Uint8Array(n);
  globalThis.crypto.getRandomValues(out);
  return out;
}

/** URL-safe random token. 16 bytes = 128 bits, 32 bytes = 256 bits. */
export function randomToken(bytes = 32): string {
  return bytesToBase64Url(randomBytes(bytes));
}

/** Unambiguous uppercase code (no 0/O/1/I/L) using rejection sampling. */
export const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
export function randomCode(length = 6): string {
  let out = "";
  const limit = 256 - (256 % CODE_ALPHABET.length);
  while (out.length < length) {
    for (const b of randomBytes(length * 2)) {
      if (b < limit) out += CODE_ALPHABET[b % CODE_ALPHABET.length];
      if (out.length === length) break;
    }
  }
  return out;
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const n = (bytes[i]! << 16) | (bytes[i + 1]! << 8) | bytes[i + 2]!;
    out += B64URL[n >> 18]! + B64URL[(n >> 12) & 63]! + B64URL[(n >> 6) & 63]! + B64URL[n & 63]!;
  }
  const rest = bytes.length - i;
  if (rest === 1) {
    const n = bytes[i]! << 16;
    out += B64URL[n >> 18]! + B64URL[(n >> 12) & 63]!;
  } else if (rest === 2) {
    const n = (bytes[i]! << 16) | (bytes[i + 1]! << 8);
    out += B64URL[n >> 18]! + B64URL[(n >> 12) & 63]! + B64URL[(n >> 6) & 63]!;
  }
  return out;
}

export function base64UrlToBytes(s: string): Uint8Array {
  const clean = s.replace(/=+$/, "");
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let buf = 0;
  let bits = 0;
  let o = 0;
  for (const ch of clean) {
    let v = B64URL.indexOf(ch);
    if (v < 0) v = ch === "+" ? 62 : ch === "/" ? 63 : -1;
    if (v < 0) throw new Error("invalid base64");
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (buf >> bits) & 0xff;
    }
  }
  return out.subarray(0, o);
}

/** Constant-time string comparison for tokens. */
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
