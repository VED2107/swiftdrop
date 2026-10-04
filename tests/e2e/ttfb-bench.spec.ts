import { mkdir, open, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, type Page } from "@playwright/test";

// Selection -> first byte, phone -> PC, through the real UI: "Send photos", the picker,
// the review sheet's Send, the real engine, the real Node receiver writing to disk.
// The phone is Chromium with an iPhone user agent on this PC's loopback: it measures
// SwiftDrop's own latency, not iOS's picker export or Wi-Fi. Real-iPhone numbers come from
// the on-device panel (?debug=1) — see docs/BENCHMARKS.md.
// Opt-in:  SD_TTFB_BENCH=1 npx playwright test tests/e2e/ttfb-bench.spec.ts
// Bigger videos: SD_TTFB_BIG_GB=5,10
test.skip(!process.env.SD_TTFB_BENCH, "benchmark: set SD_TTFB_BENCH=1");
test.setTimeout(60 * 60_000);

const BASE_HOST = "http://localhost:8799";
const BASE_PHONE = "http://127.0.0.1:8799";
const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

interface Case {
  name: string;
  count: number;
  size: number;
  ext: string;
}

const MB = 1 << 20;
const CASES: Case[] = [
  { name: "1 photo", count: 1, size: 3 * MB, ext: "heic" },
  { name: "10 photos", count: 10, size: 3 * MB, ext: "heic" },
  { name: "100 photos", count: 100, size: 3 * MB, ext: "heic" },
  { name: "1 GB video", count: 1, size: 1024 * MB, ext: "mov" },
  ...(process.env.SD_TTFB_BIG_GB ?? "")
    .split(",")
    .filter(Boolean)
    .map((g) => ({ name: `${g} GB video`, count: 1, size: Number(g) * 1024 * MB, ext: "mov" })),
  { name: "100 small files", count: 100, size: 50 * 1024, ext: "txt" },
  { name: "1,000 small files", count: 1000, size: 50 * 1024, ext: "txt" },
];

async function makeFiles(dir: string, c: Case, tag: string): Promise<string[]> {
  const out: string[] = [];
  const chunk = Buffer.alloc(Math.min(c.size, 4 * MB));
  for (let i = 0; i < chunk.length; i += 4096) chunk[i] = (i / 4096) & 255;
  for (let i = 0; i < c.count; i++) {
    const p = join(dir, `${tag}_${String(i).padStart(4, "0")}.${c.ext}`);
    if (c.size <= chunk.length) await writeFile(p, chunk.subarray(0, c.size));
    else {
      const fh = await open(p, "w");
      for (let at = 0; at < c.size; at += chunk.length) await fh.write(chunk, 0, Math.min(chunk.length, c.size - at));
      await fh.close();
    }
    out.push(p);
  }
  return out;
}

async function pairPhone(browser: import("@playwright/test").Browser): Promise<{ host: Page; phone: Page }> {
  const host = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  await host.goto(BASE_HOST);
  const pairing = (await (await host.request.get(`${BASE_HOST}/api/host/pairing`)).json()) as { url: string };
  const phone = await (await browser.newContext({ viewport: { width: 390, height: 844 }, userAgent: IPHONE_UA, isMobile: true, hasTouch: true })).newPage();
  await phone.goto(`${BASE_PHONE}/#p=${pairing.url.split("#p=")[1]}`);
  await host.getByRole("button", { name: "Allow" }).click();
  await expect(phone.getByRole("button", { name: /Send photos/ })).toBeEnabled();
  return { host, phone };
}

test("selection -> first byte, iPhone UA -> PC", async ({ browser }) => {
  const dir = join(tmpdir(), `sd-ttfb-${Date.now()}`);
  await mkdir(dir, { recursive: true });
  const { host, phone } = await pairPhone(browser);
  const rows: Array<Record<string, string | number | null>> = [];

  for (const [n, c] of CASES.entries()) {
    const files = await makeFiles(dir, c, `r${Date.now().toString(36)}_${n}`);
    const chooser = phone.waitForEvent("filechooser");
    await phone.getByRole("button", { name: /Send photos/ }).click();
    await (await chooser).setFiles(files);
    const sendBtn = phone.getByRole("button", { name: new RegExp(`^Send ${c.count.toLocaleString("en-US")} item`) });
    const t0 = Date.now();
    await sendBtn.click();
    await expect(phone.getByText("Transfer complete")).toBeVisible({ timeout: 30 * 60_000 });
    const totalS = (Date.now() - t0) / 1000;

    const report = await phone.evaluate(() => (window as unknown as { __sdLatency?: Array<Record<string, number | string | null>> }).__sdLatency?.at(-1) ?? null) as Record<string, number | null> & { transferId?: string } | null;
    const stats = (await (await host.request.get(`${BASE_HOST}/api/stats`)).json()) as {
      rss: number;
      arrivals: Array<{ transferId: string; createToFirstByteMs: number | null; createToFirstFileMs: number | null }>;
    };
    const arr = stats.arrivals.find((a) => a.transferId === report?.transferId);
    const tel = await phone.evaluate(() => {
      const mem = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
      return mem ? mem.usedJSHeapSize : null;
    });
    rows.push({
      case: c.name,
      "send→UI": report?.sendToUiMs ?? null,
      "send→start": report?.sendToStartMs ?? null,
      create: report?.createMs ?? null,
      "send→first read": report?.sendToFirstReadMs ?? null,
      "send→first byte out": report?.sendToFirstByteMs ?? null,
      "PC create→first byte": arr?.createToFirstByteMs ?? null,
      "send→first ack": report?.sendToFirstAckMs ?? null,
      "send→first file": report?.sendToFirstFileMs ?? null,
      "total s": Math.round(totalS * 10) / 10,
      "MB/s": Math.round((c.count * c.size) / MB / totalS),
      "phone heap MB": tel === null ? null : Math.round(tel / MB),
      "PC RSS MB": Math.round(stats.rss / MB),
    });
    // Back to the home screen for the next case.
    await phone.getByRole("button", { name: /^(Send more|Done)$/ }).click();
    await expect(phone.getByText("Transfer complete")).toBeHidden();
  }

  console.log("\nSelection -> first byte (ms), Chromium iPhone UA on loopback\n");
  console.table(rows);
  await writeFile(join("test-results", "ttfb-bench.json"), JSON.stringify(rows, null, 2));
  expect(rows.every((r) => typeof r["send→first byte out"] === "number")).toBe(true);
});
