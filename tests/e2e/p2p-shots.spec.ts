import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
// Design review captures (impeccable finish round): SD_SHOTS=1 npx playwright test tests/e2e/p2p-shots.spec.ts
test.skip(!process.env.SD_SHOTS, "screenshots: set SD_SHOTS=1");
test.use({ launchOptions: { args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] } });
test.setTimeout(240_000);
const BASE = "http://localhost:8799/p2p.html";
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
for (const vp of [{ n: "mobile", w: 390, h: 844, m: true }, { n: "desktop", w: 1440, h: 900, m: false }]) {
  test(`shots ${vp.n}`, async ({ browser }) => {
    const dir = await mkdtemp(join(tmpdir(), "sd-shots-"));
    const big = Buffer.alloc(160 << 20, 3);
    await writeFile(join(dir, "IMG_3921.HEIC"), big);
    await writeFile(join(dir, "notes.pdf"), Buffer.alloc(200_000, 1));
    const o = { viewport: { width: vp.w, height: vp.h }, ...(vp.m ? { userAgent: UA, isMobile: true, hasTouch: true } : {}), reducedMotion: "reduce" as const };
    const a = await (await browser.newContext(o)).newPage();
    const b = await (await browser.newContext(o)).newPage();
    await a.goto(BASE);
    await a.evaluate(() => localStorage.setItem("sd.p2p.history", JSON.stringify([
      { id: "x1", label: "12 photos", dir: "received", peer: "iPhone", files: 12, bytes: 48_200_000, seconds: 6, at: Date.now() - 120000, kind: "image" },
      { id: "x2", label: "Trip.MOV", dir: "sent", peer: "Android phone", files: 1, bytes: 1_830_000_000, seconds: 140, at: Date.now() - 3600_000 * 5, kind: "video" },
    ])));
    await a.reload();
    await a.waitForTimeout(600);
    await a.screenshot({ path: `.impeccable/review/${vp.n}-1-home.png`, fullPage: true });
    const ch = a.waitForEvent("filechooser");
    await a.getByRole("button", { name: /^Send/ }).click();
    await (await ch).setFiles([join(dir, "IMG_3921.HEIC"), join(dir, "notes.pdf")]);
    const el = a.getByTestId("signal");
    await expect(el).toBeVisible({ timeout: 15000 });
    await a.waitForTimeout(500);
    await a.screenshot({ path: `.impeccable/review/${vp.n}-2-code.png`, fullPage: true });
    const link = (await el.getAttribute("data-signal"))!;
    await b.goto(BASE);
    await b.getByRole("button", { name: /^Receive/ }).click();
    await b.waitForTimeout(500);
    await b.screenshot({ path: `.impeccable/review/${vp.n}-3-scan.png`, fullPage: true });
    await b.goto(link);
    await expect(b.getByRole("button", { name: "Accept" })).toBeVisible({ timeout: 20000 });
    await b.waitForTimeout(400);
    await b.screenshot({ path: `.impeccable/review/${vp.n}-4-accept.png`, fullPage: true });
    await b.getByRole("button", { name: "Accept" }).click();
    await a.waitForTimeout(3500);
    await a.screenshot({ path: `.impeccable/review/${vp.n}-5-sending.png`, fullPage: true });
    await b.screenshot({ path: `.impeccable/review/${vp.n}-6-receiving.png`, fullPage: true });
    await expect(b.locator(".swap-enter").getByTestId("receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 120000 });
    await a.waitForTimeout(800);
    await a.screenshot({ path: `.impeccable/review/${vp.n}-7-done-sender.png`, fullPage: true });
    await b.screenshot({ path: `.impeccable/review/${vp.n}-8-done-receiver.png`, fullPage: true });
    await b.getByRole("button", { name: "Done" }).click();
    await b.waitForTimeout(500);
    await b.screenshot({ path: `.impeccable/review/${vp.n}-9-connected.png`, fullPage: true });
  });
}
