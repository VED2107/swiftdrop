import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { expect, test } from "@playwright/test";

// Screenshots of the phone page for the public site: paired, sending, complete.
// Opt-in:  SD_SITE_SHOTS=1 npx playwright test tests/e2e/site-shots.spec.ts
// Writes apps/site/public/shots/phone-*.png at 3x (iPhone 15 Pro viewport).
test.skip(!process.env.SD_SITE_SHOTS, "screenshots: set SD_SITE_SHOTS=1");
test.setTimeout(120_000);

const BASE_HOST = "http://localhost:8799";
const BASE_PHONE = "http://127.0.0.1:8799";
const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const OUT = resolve("apps/site/public/shots");

test("phone page shots", async ({ browser }) => {
  await mkdir(OUT, { recursive: true });
  const host = await (await browser.newContext()).newPage();
  await host.goto(BASE_HOST);
  // The folder name shows on the phone ("They land in …"): give it the product's default.
  const dest = resolve("test-results/site-shots/SwiftDrop");
  await mkdir(dest, { recursive: true });
  await host.request.patch(`${BASE_HOST}/api/host/settings`, { data: { destination: dest } });
  const pairing = (await (await host.request.get(`${BASE_HOST}/api/host/pairing`)).json()) as { url: string };

  const ctx = await browser.newContext({ viewport: { width: 393, height: 852 }, deviceScaleFactor: 3, userAgent: IPHONE_UA, isMobile: true, hasTouch: true });
  const phone = await ctx.newPage();
  await phone.goto(`${BASE_PHONE}/#p=${pairing.url.split("#p=")[1]}`);
  await host.getByRole("button", { name: "Allow" }).click();
  await expect(phone.getByRole("button", { name: /Send photos/ })).toBeEnabled();
  await phone.waitForTimeout(900);
  await phone.screenshot({ path: join(OUT, "phone-home.png") });

  const dir = await mkdtemp(join(tmpdir(), "sd-shots-"));
  const files: string[] = [];
  const chunk = Buffer.alloc(8 << 20);
  for (let i = 0; i < chunk.length; i += 4096) chunk[i] = (i / 4096) & 255;
  for (let i = 0; i < 18; i++) {
    const p = join(dir, `IMG_${4810 + i}.HEIC`);
    await writeFile(p, chunk);
    files.push(p);
  }
  const big = join(dir, "IMG_4830.MOV");
  await writeFile(big, Buffer.concat(Array.from({ length: 60 }, () => chunk)));
  files.push(big);

  const chooser = phone.waitForEvent("filechooser");
  await phone.getByRole("button", { name: /Send photos/ }).click();
  await (await chooser).setFiles(files);
  await phone.waitForTimeout(500);
  await phone.screenshot({ path: join(OUT, "phone-review.png") });
  // Slow the wire so the live screen is on long enough to photograph.
  const cdp = await ctx.newCDPSession(phone);
  await cdp.send("Network.emulateNetworkConditions", { offline: false, latency: 4, downloadThroughput: -1, uploadThroughput: 40 * 1024 * 1024 });
  await phone.getByRole("button", { name: /^Send 19 items/ }).click();
  await expect(phone.getByText("Sending to your PC")).toBeVisible();
  await phone.waitForTimeout(4500);
  await phone.screenshot({ path: join(OUT, "phone-sending.png") });
  await cdp.send("Network.emulateNetworkConditions", { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  await expect(phone.getByText("Transfer complete")).toBeVisible({ timeout: 90_000 });
  await phone.waitForTimeout(1200);
  await phone.screenshot({ path: join(OUT, "phone-done.png") });
});
