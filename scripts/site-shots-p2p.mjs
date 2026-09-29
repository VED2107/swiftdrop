/**
 * Real screenshots of phone to phone for the landing page (no mock UI): serves the built
 * app, runs two simulated iPhones through pairing and a transfer over a real WebRTC link,
 * and captures each screen.
 *   node scripts/site-shots-p2p.mjs   (needs apps/web/dist: pnpm build; and ffmpeg for WebP)
 */
import { chromium } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { copyFileSync, createReadStream, existsSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { extname, join, normalize } from "node:path";

const out = "apps/site/public/shots";
const root = "apps/web/dist";
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".woff2": "font/woff2", ".webmanifest": "application/manifest+json", ".ico": "image/x-icon" };
const server = createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^([/\\])+/, "");
  const file = join(root, path || "p2p.html");
  if (!file.startsWith(normalize(root)) || !existsSync(file) || !statSync(file).isFile()) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
  createReadStream(file).pipe(res);
}).listen(8834);

const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const BASE = "http://localhost:8834/p2p.html";
const dir = mkdtempSync(join(tmpdir(), "sd-p2p-shots-"));
const files = [];
for (const n of ["01", "03", "05", "07", "09", "11"]) {
  const f = join(dir, `IMG_40${n}.JPG`);
  copyFileSync(`apps/site/public/frames/f${n}.webp`, f);
  files.push(f);
}
const clip = join(dir, "IMG_4112.MOV");
writeFileSync(clip, Buffer.alloc(900 << 20, 3));
files.push(clip);

// Loopback timings are not Wi-Fi speeds: never show them as if they were.
const scrub = () => {
  for (const el of document.querySelectorAll("main *")) {
    const t = el.children.length === 0 ? (el.textContent ?? "") : "";
    if (/^(Sent to|Received from) .+ in /.test(t)) el.textContent = t.replace(/ in .*$/, "");
    else if (/MB\/s|left$|Estimating|^speed$/.test(t)) el.style.visibility = "hidden";
  }
  for (const el of document.querySelectorAll("main .num")) if (/^\d+(\.\d)?MB\/s$/.test(el.textContent ?? "")) el.style.visibility = "hidden";
};

const browser = await chromium.launch({ args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] });
const shots = [];
const shot = async (p, name) => {
  await p.evaluate(scrub);
  await p.screenshot({ path: join(dir, `${name}.png`) });
  shots.push(name);
};
try {
  const opts = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, userAgent: UA, isMobile: true, hasTouch: true, colorScheme: "dark", reducedMotion: "reduce" };
  const a = await (await browser.newContext(opts)).newPage();
  const b = await (await browser.newContext(opts)).newPage();
  await a.goto(BASE);
  await a.waitForTimeout(600);
  await shot(a, "p2p-home");

  const pick = async (p) => {
    const chooser = p.waitForEvent("filechooser");
    await p.getByRole("button", { name: "Send" }).click();
    await (await chooser).setFiles(files);
    await p.getByRole("button", { name: "Show code to the other phone" }).click();
    return p.getByTestId("signal").getAttribute("data-signal");
  };
  // The code on the page is a real one. Draw it in a default browser, where candidates carry
  // mDNS names rather than this machine's addresses (the two loopback phones below need them).
  const plain = await chromium.launch();
  try {
    const c = await (await plain.newContext(opts)).newPage();
    await c.goto(BASE);
    await pick(c);
    await c.waitForTimeout(600);
    await shot(c, "p2p-code");
  } finally {
    await plain.close();
  }

  const offer = await pick(a);

  await b.goto(offer);
  const answer = await b.getByTestId("signal").getAttribute("data-signal");
  await a.getByRole("button", { name: "Scan its reply" }).click();
  await a.getByLabel("Paste code").fill(answer);
  await a.getByRole("button", { name: "Use code" }).click();
  await b.getByRole("dialog", { name: "Incoming files" }).waitFor({ timeout: 20_000 });
  await b.waitForTimeout(800);
  await shot(b, "p2p-incoming");

  await b.getByRole("button", { name: "Accept" }).click();
  await b.waitForFunction(() => {
    const bar = document.querySelector("[role=progressbar]");
    return bar && Number(bar.getAttribute("aria-valuenow")) >= 38;
  }, null, { timeout: 120_000 });
  await b.waitForTimeout(500);
  await shot(b, "p2p-receiving");

  await b.locator('[data-testid="receive-progress"][data-state="complete"]').waitFor({ timeout: 240_000 });
  await b.waitForTimeout(1200);
  await shot(b, "p2p-verified");
} finally {
  await browser.close();
  server.close();
}
for (const s of shots) execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", join(dir, `${s}.png`), "-c:v", "libwebp", "-quality", "86", join(out, `${s}.webp`)]);
rmSync(dir, { recursive: true, force: true });
console.log(`wrote ${shots.map((s) => `${out}/${s}.webp`).join(", ")}`);
