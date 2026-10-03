import { chromium, type Browser, type Page } from "@playwright/test";

/**
 * Raw RTCDataChannel ceiling with no SwiftDrop code: two *separate* Chromium processes
 * (like two phones, each with its own network thread), loopback, host candidates only.
 * Blasts MB of frames with bufferedAmount backpressure and reports receive-side MB/s.
 *   npx tsx tests/performance/raw-datachannel.ts [MB]
 */
const MB = Number(process.argv[2] ?? 256);
const FRAMES = [16, 64, 256];
const HIGH = [1, 4, 16];
const args = ["--disable-features=WebRtcHideLocalIpsWithMdns"];

async function page(b: Browser): Promise<Page> {
  const p = await (await b.newContext()).newPage();
  await p.goto("about:blank");
  return p;
}

async function run(a: Page, b: Page, frameKiB: number, highMiB: number): Promise<number> {
  const offer = await a.evaluate(async () => {
    const pc = new RTCPeerConnection();
    (globalThis as any).pc = pc;
    (globalThis as any).ch = pc.createDataChannel("x", { ordered: true });
    await pc.setLocalDescription(await pc.createOffer());
    await new Promise<void>((r) => (pc.iceGatheringState === "complete" ? r() : pc.addEventListener("icegatheringstatechange", () => pc.iceGatheringState === "complete" && r())));
    return pc.localDescription!.sdp;
  });
  const answer = await b.evaluate(async (sdp) => {
    const pc = new RTCPeerConnection();
    (globalThis as any).pc = pc;
    (globalThis as any).got = new Promise<RTCDataChannel>((r) => pc.addEventListener("datachannel", (e) => r(e.channel)));
    await pc.setRemoteDescription({ type: "offer", sdp });
    await pc.setLocalDescription(await pc.createAnswer());
    await new Promise<void>((r) => (pc.iceGatheringState === "complete" ? r() : pc.addEventListener("icegatheringstatechange", () => pc.iceGatheringState === "complete" && r())));
    return pc.localDescription!.sdp;
  }, offer);
  await a.evaluate(async (sdp) => {
    await (globalThis as any).pc.setRemoteDescription({ type: "answer", sdp });
    const ch: RTCDataChannel = (globalThis as any).ch;
    if (ch.readyState !== "open") await new Promise((r) => ch.addEventListener("open", r));
  }, answer);
  const total = MB << 20;
  const recv = b.evaluate(async (total) => {
    const ch: RTCDataChannel = await (globalThis as any).got;
    ch.binaryType = "arraybuffer";
    let n = 0;
    let t0 = 0;
    return new Promise<number>((r) => {
      ch.onmessage = (e) => {
        if (!t0) t0 = performance.now();
        n += (e.data as ArrayBuffer).byteLength;
        if (n >= total) r(n / 1e6 / ((performance.now() - t0) / 1000));
      };
    });
  }, total);
  await a.evaluate(
    async ({ total, frame, high }) => {
      const ch: RTCDataChannel = (globalThis as any).ch;
      ch.bufferedAmountLowThreshold = high / 4;
      const buf = new Uint8Array(frame);
      let sent = 0;
      while (sent < total) {
        while (ch.bufferedAmount + frame > high) await new Promise((r) => ch.addEventListener("bufferedamountlow", r, { once: true }));
        ch.send(buf);
        sent += frame;
      }
    },
    { total, frame: frameKiB * 1024, high: highMiB << 20 },
  );
  const mbs = await recv;
  await a.evaluate(() => (globalThis as any).pc.close());
  await b.evaluate(() => (globalThis as any).pc.close());
  return Math.round(mbs * 10) / 10;
}

const A = await chromium.launch({ args });
const B = await chromium.launch({ args });
const rows: Array<Record<string, number>> = [];
for (const f of FRAMES) {
  for (const h of HIGH) {
    const mbs = await run(await page(A), await page(B), f, h);
    rows.push({ frameKiB: f, highMiB: h, MBs: mbs });
    console.log(JSON.stringify(rows.at(-1)));
  }
}
await A.close();
await B.close();
