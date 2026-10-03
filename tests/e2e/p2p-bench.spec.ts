import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, type Page } from "@playwright/test";

// Full-app phone-to-phone throughput between two Chromium profiles on loopback: the real
// pages, the real engine, OPFS on the receiver. A software ceiling, not Wi-Fi; both
// profiles share one browser process here, as in the 2026-09-28 baseline.
// Opt-in:  SD_P2P_BENCH=1 npx playwright test tests/e2e/p2p-bench.spec.ts
// Knobs swept: send-buffer high-water mark and message size. Also records first-byte timing.
test.skip(!process.env.SD_P2P_BENCH, "benchmark: set SD_P2P_BENCH=1");
test.use({ launchOptions: { args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] } });
test.setTimeout(30 * 60_000);

const SIZE_MB = Number(process.env.SD_P2P_MB ?? 256);
const SMALL = Number(process.env.SD_P2P_SMALL ?? 1000);
const CASES = [
  { hw: 1024, frame: 64 },
  { hw: 4096, frame: 64 },
  { hw: 8192, frame: 64 },
  { hw: 16384, frame: 64 },
  { hw: 8192, frame: 16 },
  { hw: 8192, frame: 256 },
];

const live = (p: Page, id: string) => p.locator(".swap-enter").getByTestId(id);

async function pair(url: string, files: string[], browser: import("@playwright/test").Browser) {
  const a = await (await browser.newContext()).newPage();
  const b = await (await browser.newContext()).newPage();
  await a.goto(url);
  const chooser = a.waitForEvent("filechooser");
  await a.getByRole("button", { name: /^Send/ }).click();
  await (await chooser).setFiles(files);
  const el = a.getByTestId("signal");
  await expect(el).toBeVisible({ timeout: 15_000 });
  const link = (await el.getAttribute("data-signal"))!;
  await b.goto(`${url}${link.slice(link.indexOf("#"))}`);
  await b.getByRole("button", { name: "Accept" }).click({ timeout: 30_000 });
  const t0 = Date.now();
  return { a, b, t0 };
}

test("phone-to-phone throughput sweep (large file) and small-file rate", async ({ browser }) => {
  const dir = await mkdtemp(join(tmpdir(), "sd-p2pb-"));
  const file = join(dir, "big.bin");
  const buf = Buffer.alloc(SIZE_MB << 20);
  for (let i = 0; i < buf.length; i += 4093) buf[i] = i & 255;
  await writeFile(file, buf);
  const rows: Array<Record<string, number | string>> = [];
  for (const c of process.env.SD_P2P_ONLY_SMALL ? [] : CASES) {
    const url = `http://localhost:8799/p2p.html?hw=${c.hw}&frame=${c.frame}&debug=1`;
    const { a, b, t0 } = await pair(url, [file], browser);
    await expect(live(b, "receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 20 * 60_000 });
    const s = (Date.now() - t0) / 1000;
    const firstSend = await a.getByTestId("debug").locator("div", { hasText: /^accept → first send/ }).locator("dd").textContent();
    rows.push({ hwKiB: c.hw, frameKiB: c.frame, MBs: Math.round((buf.length / 1e6 / s) * 10) / 10, acceptToFirstSend: firstSend ?? "" });
    console.log(JSON.stringify(rows[rows.length - 1]));
    await a.context().close();
    await b.context().close();
  }

  // Small files: SMALL × 10 KB, default knobs
  const sdir = await mkdtemp(join(tmpdir(), "sd-p2ps-"));
  const smalls: string[] = [];
  for (let i = 0; i < SMALL; i++) {
    const p = join(sdir, `f${i}.txt`);
    await writeFile(p, Buffer.alloc(10_000, i & 255));
    smalls.push(p);
  }
  const { a, b, t0 } = await pair("http://localhost:8799/p2p.html?debug=1", smalls, browser);
  await expect(live(b, "receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 10 * 60_000 });
  const ss = (Date.now() - t0) / 1000;
  await a.waitForTimeout(1200);
  const flat = (s: string) => s.split(/\s*\n\s*/).join(" | ");
  console.log("SENDER", flat(await a.getByTestId("debug").innerText()));
  console.log("RECEIVER", flat(await b.getByTestId("debug").innerText()));
  const small = { files: SMALL, fileKB: 10, seconds: Math.round(ss * 100) / 100, filesPerSec: Math.round(SMALL / ss) };
  console.log(JSON.stringify(small));
  await a.context().close();
  await b.context().close();

  await writeFile(
    `tests/performance/results/p2p-chromium-loopback-v2.json`,
    JSON.stringify({ at: new Date().toISOString(), sizeMb: SIZE_MB, harness: "two contexts, one headless Chromium, loopback, OPFS receiver", rows, small }, null, 2),
  );
});
