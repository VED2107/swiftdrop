import { describe, expect, it } from "vitest";
import { CreateTransferSchema, decodeBatch, encodeBatchHeader, PROTOCOL_VERSION, ProtocolError, userMessageFor } from "./index.ts";

describe("batch frame", () => {
  it("round-trips header and payload", () => {
    const header = { files: [{ id: "file_0001", size: 3, hash: "aa" }, { id: "file_0002", size: 2, hash: "bb" }] };
    const head = encodeBatchHeader(header);
    const frame = new Uint8Array(head.length + 5);
    frame.set(head);
    frame.set([1, 2, 3, 4, 5], head.length);
    const out = decodeBatch(frame);
    expect(out.header).toEqual(header);
    expect(Array.from(out.payload)).toEqual([1, 2, 3, 4, 5]);
  });
  it("rejects size mismatch and garbage", () => {
    const head = encodeBatchHeader({ files: [{ id: "file_0001", size: 10, hash: "aa" }] });
    expect(() => decodeBatch(head)).toThrow(ProtocolError);
    expect(() => decodeBatch(new Uint8Array([255, 255, 255, 255, 0]))).toThrow(ProtocolError);
  });
});

describe("schemas", () => {
  const base = {
    protocol: PROTOCOL_VERSION,
    transferId: "tr_abcdef",
    direction: "to-host",
    files: [{ id: "file_0001", name: "IMG_0001.HEIC", size: 10 }],
  };
  it("applies defaults", () => {
    const t = CreateTransferSchema.parse(base);
    expect(t.integrity).toBe("xxh64");
    expect(t.onConflict).toBe("ask");
    expect(t.files[0]!.relDir).toBe("");
  });
  it("rejects negative sizes, bad ids, wrong protocol", () => {
    expect(() => CreateTransferSchema.parse({ ...base, files: [{ id: "x", name: "a", size: 1 }] })).toThrow();
    expect(() => CreateTransferSchema.parse({ ...base, files: [{ id: "file_0001", name: "a", size: -1 }] })).toThrow();
    expect(() => CreateTransferSchema.parse({ ...base, protocol: 2 })).toThrow();
  });
  it("maps codes to human messages", () => {
    expect(userMessageFor("NETWORK")).toMatch(/Reconnecting/);
    expect(userMessageFor("weird")).toMatch(/unexpected/);
  });
});
