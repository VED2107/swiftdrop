import { describe, expect, it } from "vitest";
import { createNodeBlockHasher } from "./node.ts";
import { base64UrlToBytes, bytesToBase64Url, CODE_ALPHABET, createBlockHasher, randomCode, randomToken, safeEqual } from "./index.ts";

describe("tokens", () => {
  it("produces 256-bit url-safe tokens", () => {
    const t = randomToken(32);
    expect(t).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(randomToken(32)).not.toBe(t);
  });
  it("produces unambiguous codes", () => {
    for (let i = 0; i < 50; i++) {
      const c = randomCode(6);
      expect(c).toHaveLength(6);
      for (const ch of c) expect(CODE_ALPHABET).toContain(ch);
    }
  });
  it("round-trips base64url", () => {
    for (const len of [0, 1, 2, 3, 31, 32, 33]) {
      const bytes = new Uint8Array(len).map((_, i) => (i * 37) & 255);
      expect(Array.from(base64UrlToBytes(bytesToBase64Url(bytes)))).toEqual(Array.from(bytes));
    }
  });
  it("compares safely", () => {
    expect(safeEqual("abc", "abc")).toBe(true);
    expect(safeEqual("abc", "abd")).toBe(false);
    expect(safeEqual("abc", "ab")).toBe(false);
  });
});

describe("block hasher", () => {
  for (const algo of ["xxh64", "sha256"] as const) {
    it(`${algo}: per-block digests are position-independent and detect corruption`, async () => {
      const h = await createBlockHasher(algo);
      const data = new Uint8Array(2500).map((_, i) => i & 255);
      const all = h.hashBlocks(data, 1000);
      const len = algo === "xxh64" ? 8 : 32;
      expect(all.length).toBe(3 * len);
      const second = h.hashBlocks(data.subarray(1000, 2000), 1000);
      expect(Array.from(second)).toEqual(Array.from(all.subarray(len, 2 * len)));
      const bad = data.slice();
      bad[1500] = bad[1500]! ^ 1;
      expect(Array.from(h.hashBlocks(bad, 1000).subarray(len, 2 * len))).not.toEqual(Array.from(second));
      expect(h.root(all)).toMatch(/^[0-9a-f]+$/);
    });
  }
  it("sha256 matches known vector", async () => {
    const h = await createBlockHasher("sha256");
    const d = h.hashBlocks(new TextEncoder().encode("abc"), 1024);
    const hex = Array.from(d, (b) => b.toString(16).padStart(2, "0")).join("");
    expect(hex).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });
  it("node:crypto sha256 matches the wasm digests the browser sends", async () => {
    const wasm = await createBlockHasher("sha256");
    const native = await createNodeBlockHasher("sha256");
    for (const size of [0, 1, 999, 1000, 2500]) {
      const data = new Uint8Array(size).map((_, i) => (i * 31) & 255);
      const a = wasm.hashBlocks(data, 1000);
      expect(Array.from(native.hashBlocks(data, 1000))).toEqual(Array.from(a));
      expect(native.root(a)).toBe(wasm.root(a));
    }
    expect((await createNodeBlockHasher("xxh64")).algo).toBe("xxh64");
  });
});
