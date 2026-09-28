import { createHash } from "node:crypto";
import { createBlockHasher, HASH_LENGTH, type BlockHasher, type HashAlgo } from "./index.ts";

/**
 * Server-side block hasher. SHA-256 goes through node:crypto (OpenSSL, SHA-NI where the CPU
 * has it): ~2x the wasm build on the receiver. xxh64 has no native Node equivalent and the
 * wasm one already runs at several GB/s. Digests are identical to the browser's.
 */
export async function createNodeBlockHasher(algo: HashAlgo): Promise<BlockHasher> {
  if (algo !== "sha256") return createBlockHasher(algo);
  const len = HASH_LENGTH.sha256;
  return {
    algo,
    hashBlocks(data, blockSize) {
      const count = Math.max(1, Math.ceil(data.byteLength / blockSize));
      const out = new Uint8Array(count * len);
      for (let i = 0; i < count; i++) {
        const digest = createHash("sha256")
          .update(data.subarray(i * blockSize, Math.min(data.byteLength, (i + 1) * blockSize)))
          .digest();
        out.set(digest, i * len);
      }
      return out;
    },
    root(blockHashes) {
      return createHash("sha256").update(blockHashes).digest("hex");
    },
  };
}
