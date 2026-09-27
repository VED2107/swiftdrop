import { describe, expect, it } from "vitest";
import { Bitset, formatBytes, formatDuration, numberedName, sanitizeFileName, sanitizeRelativeDir } from "./index.ts";

describe("sanitizeFileName", () => {
  it("strips separators and traversal", () => {
    expect(sanitizeFileName("../../etc/passwd")).toBe(".._.._etc_passwd");
    expect(sanitizeFileName("..\\..\\Windows\\win.ini")).toBe(".._.._Windows_win.ini");
    expect(sanitizeFileName("..")).toBe("file");
  });
  it("escapes Windows reserved names and trailing dots", () => {
    expect(sanitizeFileName("CON")).toBe("_CON");
    expect(sanitizeFileName("nul.txt")).toBe("_nul.txt");
    expect(sanitizeFileName("report. . ")).toBe("report");
  });
  it("removes control and bidi override characters", () => {
    expect(sanitizeFileName("evil\u202Egpj.exe")).toBe("evil_gpj.exe");
    expect(sanitizeFileName("a\u0000b:c?.jpg")).toBe("a_b_c_.jpg");
  });
  it("caps length but keeps extension", () => {
    const n = sanitizeFileName(`${"x".repeat(400)}.heic`);
    expect(n.length).toBe(180);
    expect(n.endsWith(".heic")).toBe(true);
  });
  it("keeps normal names untouched", () => {
    expect(sanitizeFileName("IMG_0001.HEIC")).toBe("IMG_0001.HEIC");
    expect(sanitizeFileName("Résumé 2024.pdf")).toBe("Résumé 2024.pdf");
  });
});

describe("sanitizeRelativeDir", () => {
  it("drops traversal segments and roots", () => {
    expect(sanitizeRelativeDir("../a/./b\\..\\c")).toEqual(["a", "b", "c"]);
    expect(sanitizeRelativeDir("C:\\Windows")).toEqual(["C_", "Windows"]);
    expect(sanitizeRelativeDir("")).toEqual([]);
  });
});

describe("numberedName", () => {
  it("inserts counter before extension", () => {
    expect(numberedName("IMG_001.jpg", 2)).toBe("IMG_001 (2).jpg");
    expect(numberedName("README", 1)).toBe("README (1)");
  });
});

describe("Bitset", () => {
  it("tracks, counts and round-trips", () => {
    const b = new Bitset(21);
    b.set(0);
    b.set(5);
    b.set(20);
    expect(b.set(5)).toBe(false);
    expect(b.count).toBe(3);
    const c = Bitset.fromBase64(21, b.toBase64());
    expect(c.count).toBe(3);
    expect(c.has(20)).toBe(true);
    expect(c.missingRuns()).toEqual([
      [1, 5],
      [6, 20],
    ]);
  });
  it("reports complete", () => {
    const b = new Bitset(3);
    [0, 1, 2].forEach((i) => b.set(i));
    expect(b.complete).toBe(true);
    expect(b.missingRuns()).toEqual([]);
  });
});

describe("format", () => {
  it("formats bytes and durations", () => {
    expect(formatBytes(18_700_000_000)).toBe("18.7 GB");
    expect(formatBytes(118_000_000)).toBe("118 MB");
    expect(formatDuration(161)).toBe("02:41");
    expect(formatDuration(3725)).toBe("1:02:05");
  });
});
