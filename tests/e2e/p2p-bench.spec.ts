import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, type Page } from "@playwright/test";

// Single-DataChannel throughput between two Chromium profiles on loopback (software ceiling,
// not Wi-Fi). Opt-in:  SD_P2P_BENCH=1 npx playwright test tests/e2e/p2p-bench.spec.ts
// Knobs swept: send-buffer high-water mark and frame size.
test.skip(!process.env.SD_P2P_BENCH, "benchmark: set SD_P2P_BENCH=1");
test.use({ launchOptions: { args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] } });
test.setTimeout(20 * 60_000);

const SIZE_MB = Number(process.env.SD_P2P_MB ?? 256);
const CASES = [
  { hw: 256, frame: 16 },
  { hw: 256, frame: 64 },
  { hw: 1024, frame: 64 },
  { hw: 4096, frame: 64 },
  { hw: 1024, frame: 256 },
];

async function signal(p: Page) {
  const el = p.getByTestId("signal");
  await expect(el).toBeVisible({ timeout: 15_000 });
  return (await el.getAttribute("data-signal"))!;
}

test("single DataChannel throughput sweep", async ({ browser }) => {
  const dir = await mkdtemp(join(tmpdir(), "sd-p2pb-"));
  const file = join(dir, "big.bin");
  const buf = Buffer.alloc(SIZE_MB << 20);
  for (let i = 0; i < buf.length; i += 4093) buf[i] = i & 255;
  await writeFile(file, buf);
  const rows: Array<Record<string, number>> = [];
  for (const c of CASES) {
    const url = `http://localhost:8799/p2p.html?hw=${c.hw}&frame=${c.frame}`;
    const a = await (await browser.newContext()).newPage();
    const b = await (await browser.newContext()).newPage();
    await a.goto(url);
    const chooser = a.waitForEvent("filechooser");
    await a.getByRole("button", { name: "Send" }).click();
    await (await chooser).setFiles([file]);
    await a.getByRole("button", { name: "Show code to the other phone" }).click();
    const offer = await signal(a);
    await b.goto(`http://localhost:8799/p2p.html?hw=${c.hw}&frame=${c.frame}${offer.slice(offer.indexOf("#"))}`);
    const answer = await signal(b);
    await a.getByRole("button", { name: "Scan its reply" }).click();
    await a.getByLabel("Paste code").fill(answer);
    await a.getByRole("button", { name: "Use code" }).click();
    await b.getByRole("button", { name: "Accept" }).click();
    const t0 = Date.now();
    await expect(b.getByTestId("receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 15 * 60_000 });
    const s = (Date.now() - t0) / 1000;
    rows.push({ hwKiB: c.hw, frameKiB: c.frame, MBs: Math.round((buf.length / 1e6 / s) * 10) / 10 });
    console.log(JSON.stringify(rows[rows.length - 1]));
    await a.context().close();
    await b.context().close();
  }
  await writeFile("tests/performance/results/p2p-chromium-loopback.json", JSON.stringify({ at: new Date().toISOString(), sizeMb: SIZE_MB, rows }, null, 2));
});
