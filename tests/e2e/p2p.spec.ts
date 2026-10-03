import { createHash } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, type Browser, type Page } from "@playwright/test";

// Phone ↔ phone with a real RTCPeerConnection + DataChannel between two isolated browser
// profiles. One QR: the sender shows it, the receiver scans it (here: opens its link, as the
// iPhone Camera app does, or pastes it into the in-app scanner). The answer travels back
// through the rendezvous mailbox (apps/signal on :8790), which only ever sees ciphertext.
// The page is merely *served* from localhost (a secure context, like the https host).
const BASE = "http://localhost:8799/p2p.html";
const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// Two contexts of one headless Chromium can only reach each other's host candidates when
// they aren't hidden behind mDNS names.
test.use({ launchOptions: { args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] } });

interface Traffic {
  api: string[];
  signal: Array<{ method: string; body: string | null }>;
}

function watch(page: Page): Traffic {
  const t: Traffic = { api: [], signal: [] };
  page.on("request", (r) => {
    const u = new URL(r.url());
    if (u.pathname.startsWith("/api/")) t.api.push(r.url());
    if (u.port === "8790") t.signal.push({ method: r.method(), body: r.postData() });
  });
  return t;
}

async function phones(browser: Browser) {
  const opts = { viewport: { width: 390, height: 844 }, userAgent: IPHONE_UA, isMobile: true, hasTouch: true };
  const a = await (await browser.newContext(opts)).newPage();
  const b = await (await browser.newContext(opts)).newPage();
  return { a, b };
}

async function code(page: Page): Promise<string> {
  const el = page.getByTestId("signal");
  await expect(el).toBeVisible({ timeout: 15_000 });
  return (await el.getAttribute("data-signal"))!;
}

async function send(page: Page, files: string[]) {
  const chooser = page.waitForEvent("filechooser");
  await page.getByRole("button", { name: /^Send/ }).click();
  await (await chooser).setFiles(files);
}

async function opfsDigests(page: Page): Promise<Record<number, string>> {
  return page.evaluate(async () => {
    const root = await (await navigator.storage.getDirectory()).getDirectoryHandle("swiftdrop");
    const out: Record<number, string> = {};
    for await (const [name, h] of (root as unknown as { entries(): AsyncIterable<[string, FileSystemHandle]> }).entries()) {
      if (name === "state" || h.kind !== "directory") continue;
      for await (const [, fh] of (h as unknown as { entries(): AsyncIterable<[string, FileSystemFileHandle]> }).entries()) {
        const file = await fh.getFile();
        const d = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
        out[file.size] = Array.from(new Uint8Array(d), (x) => x.toString(16).padStart(2, "0")).join("");
      }
    }
    return out;
  });
}

/** The screen on show: a screen that's leaving keeps its DOM for its 200 ms exit. */
const live = (p: Page, id: string) => p.locator(".swap-enter").getByTestId(id);

const sha = (buf: Buffer) => createHash("sha256").update(buf).digest("hex");

async function fixtures() {
  const dir = await mkdtemp(join(tmpdir(), "sd-p2p-"));
  const big = Buffer.alloc(24 << 20);
  for (let i = 0; i < big.length; i += 997) big[i] = (i * 31) & 255;
  await writeFile(join(dir, "clip.mov"), big);
  await writeFile(join(dir, "note.txt"), "hello, other phone");
  const extra = Buffer.alloc(3 << 20, 7);
  await writeFile(join(dir, "second.bin"), extra);
  return { dir, big, extra };
}

test("one QR: sender shows it, receiver opens it with the Camera app, files arrive byte-identical", async ({ browser }) => {
  const { dir, big } = await fixtures();
  const { a, b } = await phones(browser);
  const ta = watch(a);
  const tb = watch(b);

  // A (sender): Send opens the picker; the code appears once files are chosen
  await a.goto(BASE);
  await expect(a.locator(".p2p")).toHaveAttribute("data-state", "IDLE");
  await send(a, [join(dir, "clip.mov"), join(dir, "note.txt")]);
  await expect(a.locator(".p2p")).toHaveAttribute("data-state", "WAITING_FOR_RECEIVER");
  const link = await code(a);
  expect(link).toMatch(/#o=[DP][A-Za-z0-9_-]+&k=[A-Za-z0-9_-]{22,}/);

  // B (receiver): the Camera app opens the link; nobody scans back
  await b.goto(link);
  await expect(b.getByRole("dialog", { name: "Incoming files" })).toBeVisible({ timeout: 20_000 });
  await expect(b.getByText("wants to send 2 files")).toBeVisible();
  await expect(a.locator(".p2p")).toHaveAttribute("data-state", "AWAITING_ACCEPT");
  await b.getByRole("button", { name: "Accept" }).click();

  await expect(live(a, "send-progress")).toHaveAttribute("data-state", "complete", { timeout: 60_000 });
  await expect(live(b, "receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 60_000 });
  await expect(a.getByText("Verified")).toBeVisible();

  // The connection really is peer-to-peer on the local network
  await expect(a.getByTestId("path")).toHaveAttribute("data-kind", "local");
  await expect(b.getByTestId("path")).toHaveAttribute("data-kind", "local");

  const digests = await opfsDigests(b);
  expect(digests[big.length]).toBe(sha(big));
  expect(digests[Buffer.byteLength("hello, other phone")]).toBe(sha(Buffer.from("hello, other phone")));

  // No PC in the loop, and the rendezvous only ever carried small sealed messages
  expect(ta.api).toEqual([]);
  expect(tb.api).toEqual([]);
  const posts = [...ta.signal, ...tb.signal].filter((r) => r.method === "POST");
  expect(posts.length).toBeGreaterThanOrEqual(1);
  for (const p of posts) {
    expect(p.body).toMatch(/^1\.[A-Za-z0-9_-]+$/);
    expect(p.body!.length).toBeLessThan(4096);
  }
});

test("in-app scanner, then a second transfer on the same warm connection", async ({ browser }) => {
  const { dir, extra } = await fixtures();
  const { a, b } = await phones(browser);
  await a.goto(BASE);
  await send(a, [join(dir, "note.txt")]);
  const link = await code(a);

  await b.goto(BASE);
  await b.getByRole("button", { name: /^Receive/ }).click();
  await expect(b.locator(".p2p")).toHaveAttribute("data-state", "SCANNING");
  await b.getByLabel("Paste code").fill(link);
  await b.getByRole("button", { name: "Use code" }).click();
  await b.getByRole("button", { name: "Accept" }).click({ timeout: 20_000 });
  await expect(live(a, "send-progress")).toHaveAttribute("data-state", "complete", { timeout: 30_000 });
  await b.getByRole("button", { name: "Done" }).click();
  await expect(b.locator(".p2p")).toHaveAttribute("data-state", "CONNECTED");

  // Send more: no new pairing, the transfer screen appears straight away
  const chooser = a.waitForEvent("filechooser");
  await a.getByRole("button", { name: "Send more" }).click();
  await (await chooser).setFiles([join(dir, "second.bin")]);
  await expect(live(a, "send-progress")).not.toHaveAttribute("data-state", "complete");
  await b.getByRole("button", { name: "Accept" }).click({ timeout: 20_000 });
  await expect(live(a, "send-progress")).toHaveAttribute("data-state", "complete", { timeout: 30_000 });
  await expect(live(b, "receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 30_000 });
  expect((await opfsDigests(b))[extra.length]).toBe(sha(extra));
});

test("after connecting, the receiver sends files back on the same connection", async ({ browser }) => {
  const { dir, extra } = await fixtures();
  const { a, b } = await phones(browser);
  await a.goto(BASE);
  await send(a, [join(dir, "note.txt")]);
  await b.goto(await code(a));
  await b.getByRole("button", { name: "Accept" }).click({ timeout: 20_000 });
  await expect(live(b, "receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 30_000 });

  // B was the receiver; now it sends. No new code, no scan.
  const chooser = b.waitForEvent("filechooser");
  await b.getByRole("button", { name: "Send files back" }).click();
  await (await chooser).setFiles([join(dir, "second.bin")]);
  await expect(a.getByRole("dialog", { name: "Incoming files" })).toBeVisible({ timeout: 20_000 });
  await a.getByRole("button", { name: "Accept" }).click();
  await expect(live(b, "send-progress")).toHaveAttribute("data-state", "complete", { timeout: 30_000 });
  await expect(live(a, "receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 30_000 });
  expect((await opfsDigests(a))[extra.length]).toBe(sha(extra));
});

test("no internet: pairs with one extra scan (the receiver's reply)", async ({ browser }) => {
  const { dir } = await fixtures();
  const { a, b } = await phones(browser);
  const tb = watch(b);
  await a.goto(`${BASE}?signal=off`);
  await send(a, [join(dir, "note.txt")]);
  const link = await code(a);
  expect(link).not.toContain("&k=");

  await b.goto(`${BASE.replace("p2p.html", "p2p.html?signal=off")}${link.slice(link.indexOf("#"))}`);
  const reply = await code(b);
  expect(reply).toContain("#a=");

  await a.getByRole("button", { name: /Scan reply/ }).click();
  await a.getByLabel("Paste code").fill(reply);
  await a.getByRole("button", { name: "Use code" }).click();
  await b.getByRole("button", { name: "Accept" }).click({ timeout: 20_000 });
  await expect(live(b, "receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 30_000 });
  expect(tb.signal).toEqual([]);
});

test("debug panel reports timing and channel telemetry (hidden without ?debug)", async ({ browser }) => {
  const { dir } = await fixtures();
  const { a, b } = await phones(browser);
  await a.goto(`${BASE}?debug=1`);
  await send(a, [join(dir, "clip.mov")]);
  const link = await code(a);
  await b.goto(link);
  await b.getByRole("button", { name: "Accept" }).click({ timeout: 20_000 });
  await expect(live(a, "send-progress")).toHaveAttribute("data-state", "complete", { timeout: 60_000 });
  const panel = a.getByTestId("debug");
  await expect(panel).toContainText("job start → first send");
  await expect(panel).toContainText("bufferedAmount");
  await expect(b.getByTestId("debug")).toHaveCount(0);
});
