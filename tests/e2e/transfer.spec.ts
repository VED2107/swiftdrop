import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";

const BASE_HOST = "http://localhost:8799";
const BASE_PHONE = "http://127.0.0.1:8799";
const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

test("phone pairs by QR, PC approves, phone sends files that land byte-identical", async ({ browser }) => {
  const dir = await mkdtemp(join(tmpdir(), "sd-e2e-"));
  const big = Buffer.alloc(40 << 20);
  for (let i = 0; i < big.length; i += 4096) big[i] = (i / 4096) & 255;
  await writeFile(join(dir, "clip.mov"), big);
  await writeFile(join(dir, "note.txt"), "hello from the phone");

  const host = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  await host.goto(BASE_HOST);
  await expect(host.getByText("Scan with your phone’s camera")).toBeVisible();
  const pairing = (await (await host.request.get(`${BASE_HOST}/api/host/pairing`)).json()) as { url: string };

  const phone = await (await browser.newContext({ viewport: { width: 390, height: 844 }, userAgent: IPHONE_UA, isMobile: true, hasTouch: true })).newPage();
  await phone.goto(`${BASE_PHONE}/#p=${pairing.url.split("#p=")[1]}`);
  await expect(phone.getByText("Tap Allow on your PC")).toBeVisible();
  // the token is scrubbed from the address bar
  expect(phone.url()).not.toContain("#p=");

  await host.getByRole("button", { name: "Allow" }).click();
  await expect(phone.getByRole("button", { name: /Send photos/ })).toBeEnabled();
  await expect(host.getByText("iPhone is connected")).toBeVisible({ timeout: 10_000 });

  await phone.locator("input[type=file]").nth(1).setInputFiles([join(dir, "clip.mov"), join(dir, "note.txt")]);
  await phone.getByRole("button", { name: /^Send 2 items/ }).click();
  await expect(phone.getByText("Transfer complete")).toBeVisible({ timeout: 60_000 });

  const dest = "test-results/e2e-dest";
  expect(Buffer.compare(await readFile(join(dest, "clip.mov")), big)).toBe(0);
  expect(await readFile(join(dest, "note.txt"), "utf8")).toBe("hello from the phone");
  expect((await stat(join(dest, "clip.mov"))).size).toBe(big.length);
});

test("wrong code is rejected with a human message", async ({ browser }) => {
  const phone = await (await browser.newContext({ userAgent: IPHONE_UA })).newPage();
  await phone.goto(BASE_PHONE);
  // typing the sixth character submits on its own
  await phone.getByLabel("Character 1").fill("ZZZZZZ");
  await expect(phone.getByRole("alert")).toContainText(/expired|Too many/);
});

const ANDROID_UA =
  "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";

test("Android phone pairs by typed code and sends files", async ({ browser }) => {
  const dir = await mkdtemp(join(tmpdir(), "sd-e2e-android-"));
  const clip = Buffer.alloc(12 << 20);
  for (let i = 0; i < clip.length; i += 997) clip[i] = (i / 997) & 255;
  await writeFile(join(dir, "PXL_20260927_clip.mp4"), clip);

  const host = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
  await host.goto(BASE_HOST);
  const { code } = (await (await host.request.get(`${BASE_HOST}/api/host/pairing`)).json()) as { code: string };

  const phone = await (await browser.newContext({ viewport: { width: 412, height: 915 }, userAgent: ANDROID_UA, isMobile: true, hasTouch: true })).newPage();
  await phone.goto(BASE_PHONE);
  await phone.getByLabel("Character 1").fill(code);
  await expect(host.getByText("Android phone wants to connect")).toBeVisible();
  await host.getByRole("button", { name: "Allow" }).click();
  await expect(phone.getByText("Connected to your PC")).toBeVisible();
  await expect(phone.getByText("How Android handles this")).toBeVisible();

  await phone.locator("input[type=file]").nth(1).setInputFiles([join(dir, "PXL_20260927_clip.mp4")]);
  await phone.getByRole("button", { name: /^Send 1 item/ }).click();
  await expect(phone.getByText("Transfer complete")).toBeVisible({ timeout: 60_000 });
  expect(Buffer.compare(await readFile(join("test-results/e2e-dest", "PXL_20260927_clip.mp4")), clip)).toBe(0);
});
