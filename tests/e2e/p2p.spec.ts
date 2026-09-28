import { createHash } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, type Page } from "@playwright/test";

// Phone ↔ phone with a real RTCPeerConnection + DataChannel between two isolated browser
// profiles. The page is merely *served* from localhost here (a secure context, like the https
// host in production); the test asserts neither page ever talks to a SwiftDrop server.
const BASE = "http://localhost:8799/p2p.html";
const IPHONE_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// Two contexts of one headless Chromium can only reach each other's host candidates when
// they aren't hidden behind mDNS names.
test.use({ launchOptions: { args: ["--disable-features=WebRtcHideLocalIpsWithMdns"] } });

function watchApi(page: Page): string[] {
  const hits: string[] = [];
  page.on("request", (r) => {
    if (new URL(r.url()).pathname.startsWith("/api/")) hits.push(r.url());
  });
  return hits;
}

async function signal(page: Page): Promise<string> {
  const el = page.getByTestId("signal");
  await expect(el).toBeVisible({ timeout: 15_000 });
  return (await el.getAttribute("data-signal"))!;
}

test("phone A sends files directly to phone B over WebRTC; B stores them in OPFS byte-identical", async ({ browser }) => {
  const dir = await mkdtemp(join(tmpdir(), "sd-p2p-"));
  const big = Buffer.alloc(24 << 20);
  for (let i = 0; i < big.length; i += 997) big[i] = (i * 31) & 255;
  await writeFile(join(dir, "clip.mov"), big);
  await writeFile(join(dir, "note.txt"), "hello, other phone");

  const opts = { viewport: { width: 390, height: 844 }, userAgent: IPHONE_UA, isMobile: true, hasTouch: true };
  const a = await (await browser.newContext(opts)).newPage();
  const b = await (await browser.newContext(opts)).newPage();
  const apiA = watchApi(a);
  const apiB = watchApi(b);

  // A: pick files, show the offer
  await a.goto(BASE);
  const chooser = a.waitForEvent("filechooser");
  await a.getByRole("button", { name: "Send" }).click();
  await (await chooser).setFiles([join(dir, "clip.mov"), join(dir, "note.txt")]);
  await a.getByRole("button", { name: "Show code to the other phone" }).click();
  const offer = await signal(a);
  expect(offer).toContain("#o=");

  // B: opened by scanning A's code (the Camera app opens the link), shows its reply
  await b.goto(offer);
  const answer = await signal(b);
  expect(answer).toContain("#a=");

  // A: scan the reply (pasted here: headless has no camera)
  await a.getByRole("button", { name: "Scan its reply" }).click();
  await a.getByLabel("Paste code").fill(answer);
  await a.getByRole("button", { name: "Use code" }).click();

  // B: explicit acceptance
  await expect(b.getByRole("dialog", { name: "Incoming files" })).toBeVisible({ timeout: 20_000 });
  await expect(b.getByText("wants to send 2 files")).toBeVisible();
  await b.getByRole("button", { name: "Accept" }).click();

  await expect(a.getByTestId("send-progress")).toHaveAttribute("data-state", "complete", { timeout: 60_000 });
  await expect(b.getByTestId("receive-progress")).toHaveAttribute("data-state", "complete", { timeout: 60_000 });

  // The connection really is peer-to-peer on the local network
  await expect(a.getByTestId("path")).toHaveAttribute("data-kind", "local");
  await expect(b.getByTestId("path")).toHaveAttribute("data-kind", "local");

  // B's copies, read back from its private file system
  const digests = await b.evaluate(async () => {
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
  const sha = (buf: Buffer) => createHash("sha256").update(buf).digest("hex");
  expect(digests[big.length]).toBe(sha(big));
  expect(digests[Buffer.byteLength("hello, other phone")]).toBe(sha(Buffer.from("hello, other phone")));

  // No PC in the loop: neither phone made a single SwiftDrop API request
  expect(apiA).toEqual([]);
  expect(apiB).toEqual([]);
});
