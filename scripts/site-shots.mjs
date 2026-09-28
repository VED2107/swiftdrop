/**
 * Real screenshots of the app for the landing page (no mock UI): runs the server in its
 * test mode, pairs a simulated iPhone, sends a file, and captures each screen.
 *   node scripts/site-shots.mjs   (needs apps/web/dist: pnpm build)
 */
import { chromium } from "@playwright/test";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const out = "apps/site/public/shots";
const tmp = mkdtempSync(join(tmpdir(), "sd-shots-"));
const server = spawn(process.execPath, ["node_modules/tsx/dist/cli.mjs", "apps/server/src/main.ts"], {
  env: { ...process.env, SWIFTDROP_E2E: "1", SWIFTDROP_PORT: "8833", SWIFTDROP_NO_OPEN: "1", SWIFTDROP_DEST: join(tmp, "dest"), SWIFTDROP_STATE_DIR: join(tmp, "state"), SWIFTDROP_OUTBOX: join(tmp, "outbox"), SWIFTDROP_LOG: "warn" },
  stdio: "inherit",
});
for (let i = 0; i < 60; i++) {
  if (await fetch("http://localhost:8833/api/ping").then((r) => r.ok, () => false)) break;
  await new Promise((r) => setTimeout(r, 250));
}
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const browser = await chromium.launch();
try {
  const host = await (await browser.newContext({ viewport: { width: 1280, height: 820 }, deviceScaleFactor: 2, colorScheme: "dark" })).newPage();
  await host.goto("http://localhost:8833");
  await host.getByText("Scan the code with your phone’s camera").waitFor();
  // Show a generic LAN address instead of this machine's.
  await host.evaluate(() => {
    for (const el of document.querySelectorAll(".mono, .copy-field span")) if (/\d+\.\d+\.\d+\.\d+/.test(el.textContent ?? "")) el.textContent = (el.textContent ?? "").replace(/\d+\.\d+\.\d+\.\d+/, "192.168.1.20");
  });
  await host.waitForTimeout(1200);
  await host.screenshot({ path: `${out}/pc-pair.png` });
  const pairing = await (await host.request.get("http://localhost:8833/api/host/pairing")).json();

  const phone = await (await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, userAgent: UA, isMobile: true, hasTouch: true, colorScheme: "dark" })).newPage();
  await phone.goto(`http://127.0.0.1:8833/#p=${pairing.url.split("#p=")[1]}`);
  await phone.getByText("Tap Allow on your PC").waitFor();
  await host.getByRole("button", { name: "Allow" }).click();
  await phone.getByRole("button", { name: /Send photos/ }).waitFor();
  await phone.waitForTimeout(1800);
  await phone.screenshot({ path: `${out}/phone-ready.png` });

  const dir = mkdtempSync(join(tmpdir(), "sd-shot-files-"));
  const names = ["IMG_4102.HEIC", "IMG_4103.HEIC", "IMG_4107.MOV", "IMG_4110.HEIC"];
  for (const [i, n] of names.entries()) writeFileSync(join(dir, n), Buffer.alloc((i === 2 ? 60 : 3) << 20, i + 1));
  await phone.locator("input[type=file]").nth(1).setInputFiles(names.map((n) => join(dir, n)));
  await phone.getByRole("button", { name: /^Send 4 items/ }).click();
  await phone.getByText("Transfer complete").waitFor({ timeout: 60_000 });
  await phone.waitForTimeout(900);
  // Loopback timings are not Wi-Fi speeds: never show them as if they were. And no real user paths.
  const scrub = () => {
    for (const el of document.querySelectorAll("p, span, div")) {
      if (el.children.length === 0 && /MB\/s average/.test(el.textContent ?? "")) el.style.visibility = "hidden";
    }
    for (const el of document.querySelectorAll("*")) {
      if (el.children.length === 0 && /[A-Z]:\\Users\\/.test(el.textContent ?? "")) el.textContent = "C:\\Users\\You\\Pictures\\SwiftDrop";
    }
  };
  await phone.evaluate(scrub);
  await phone.screenshot({ path: `${out}/phone-done.png` });
  await host.waitForTimeout(600);
  await host.evaluate(scrub);
  await host.screenshot({ path: `${out}/pc-received.png` });

  // PC -> phone: offer a local folder in place, then the phone's "From your PC" row.
  const give = join(dir, "For the phone");
  mkdirSync(give, { recursive: true });
  writeFileSync(join(give, "Boarding pass.pdf"), Buffer.alloc(180_000, 7));
  writeFileSync(join(give, "Trip playlist.m4a"), Buffer.alloc(3 << 20, 8));
  await host.request.post("http://localhost:8833/api/host/offers/paths", { data: { paths: [give] } });
  await phone.getByText("From your PC").waitFor();
  await phone.getByText("From your PC").scrollIntoViewIfNeeded();
  await phone.evaluate(() => window.scrollBy(0, -260));
  await phone.waitForTimeout(700);
  await phone.screenshot({ path: `${out}/phone-offer.png` });
} finally {
  await browser.close();
  server.kill();
}
