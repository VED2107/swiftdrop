import { BLOCK_SIZE } from "@swiftdrop/protocol";
import { TransferJob, type SourceFile } from "@swiftdrop/transfer-engine";
import { describe, expect, it } from "vitest";
import { DataChannelTransport } from "./channel.ts";
import { PEER_CONTROLLER } from "./index.ts";
import { memoryLink, type MemoryLinkOptions } from "./memory-link.ts";
import { classifyPath, isLocalAddress, pathFromStats } from "./path.ts";
import { PeerTransport } from "./peer-transport.ts";
import { MemorySinkFactory, MemoryStateStore, PeerReceiver, type IncomingOffer } from "./receiver.ts";
import { decodeSignal, encodeSignal, extractSignal } from "./signal.ts";

function bytes(n: number, seed = 1): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(n);
  let x = seed * 2654435761;
  for (let i = 0; i < n; i++) {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    out[i] = x & 255;
  }
  return out;
}

let n = 0;
function source(name: string, data: Uint8Array<ArrayBuffer>, relDir = ""): SourceFile {
  return { id: `f_${String(++n).padStart(6, "0")}`, name, relDir, size: data.byteLength, type: "application/octet-stream", lastModified: 1_700_000_000_000, blob: new Blob([data]) };
}

async function link(receiver: PeerReceiver, opts: MemoryLinkOptions = {}, high = 256 * 1024) {
  const [a, b] = memoryLink(opts);
  const sender = new DataChannelTransport(a, { highWaterMark: high, lowWaterMark: high / 4 });
  const recv = new DataChannelTransport(b);
  receiver.attach(recv);
  await Promise.all([sender.connect(), recv.connect()]);
  return { sender, recv, cut: () => a.close() };
}

function setup(accept: (o: IncomingOffer) => Promise<boolean> = async () => true) {
  const sinks = new MemorySinkFactory();
  const state = new MemoryStateStore();
  const offers: IncomingOffer[] = [];
  const receiver = new PeerReceiver({ sinks, state, accept: (o) => (offers.push(o), accept(o)) });
  return { sinks, state, receiver, offers };
}

const job = (transport: PeerTransport, files: SourceFile[], extra: Partial<ConstructorParameters<typeof TransferJob>[0]> = {}) =>
  new TransferJob({ transport, files, direction: "to-peer", label: "Holiday", controller: PEER_CONTROLLER, sampleIntervalMs: 50, ...extra });

describe("phone -> phone over a DataChannel", () => {
  it("moves large, small, empty and nested files byte-for-byte after the receiver accepts", async () => {
    const { receiver, sinks, offers } = setup();
    const { sender } = await link(receiver);
    const big = bytes(6 * BLOCK_SIZE + 777, 1);
    const smalls = Array.from({ length: 40 }, (_, i) => source(`IMG_${i}.JPG`, bytes(3000 + i * 11, 10 + i), "DCIM"));
    const files = [source("clip.mov", big), source("empty.txt", new Uint8Array(0)), ...smalls];
    const j = job(new PeerTransport(sender), files);
    await j.start();
    await j.done;
    expect(j.snapshot().state).toBe("complete");
    expect(offers).toHaveLength(1);
    expect(offers[0]!.totalBytes).toBe(j.bytesTotal);

    const t = receiver.get(j.id)!;
    expect(t.filesDone).toBe(files.length);
    const got = await receiver.file(t, t.byId.get(files[0]!.id)!);
    expect(Buffer.compare(Buffer.from(await got.arrayBuffer()), Buffer.from(big))).toBe(0);
    const img = await sinks.file(j.id, smalls[7]!.id, "x", "");
    expect(Buffer.compare(Buffer.from(await img.arrayBuffer()), Buffer.from(bytes(3000 + 7 * 11, 17)))).toBe(0);
    expect((await sinks.file(j.id, files[1]!.id, "e", "")).size).toBe(0);
    expect(receiver.status(t).files.find((f) => f.id === smalls[0]!.id)!.finalName).toBe("DCIM/IMG_0.JPG");
  });

  it("stops with DECLINED when the person on the other phone says no", async () => {
    const { receiver, sinks } = setup(async () => false);
    const { sender } = await link(receiver);
    const j = job(new PeerTransport(sender), [source("a.bin", bytes(1000))]);
    await j.start();
    await j.done;
    expect(j.snapshot().state).toBe("failed");
    expect(j.snapshot().errorCode).toBe("DECLINED");
    expect(sinks.files.size).toBe(0);
  });

  it("detects a block damaged in flight and resends it", async () => {
    const { receiver } = setup();
    let hit = false;
    const { sender } = await link(receiver, {
      tamper(frame) {
        if (!hit && frame.byteLength > 1000) {
          hit = true;
          const copy = frame.slice();
          copy[500] = copy[500]! ^ 0xff;
          return copy;
        }
        return frame;
      },
    });
    const data = bytes(3 * BLOCK_SIZE, 3);
    const f = source("x.bin", data);
    const j = job(new PeerTransport(sender), [f]);
    await j.start();
    await j.done;
    expect(hit).toBe(true);
    expect(j.snapshot().state).toBe("complete");
    expect(j.snapshot().chunkFailures).toBeGreaterThanOrEqual(1);
    const t = receiver.get(j.id)!;
    const got = await receiver.file(t, t.byId.get(f.id)!);
    expect(Buffer.compare(Buffer.from(await got.arrayBuffer()), Buffer.from(data))).toBe(0);
  });

  it("survives the link dropping: re-pairing attaches a new channel and only missing blocks are sent", async () => {
    const { receiver } = setup();
    const first = await link(receiver, { rate: 20 });
    const transport = new PeerTransport(first.sender);
    const data = bytes(24 * BLOCK_SIZE, 5);
    const f = source("long.mov", data);
    const j = job(transport, [f]);
    await j.start();
    while (j.snapshot().bytesDone < 6 * BLOCK_SIZE) await new Promise((r) => setTimeout(r, 5));
    first.cut();
    while (j.snapshot().state !== "reconnecting") await new Promise((r) => setTimeout(r, 5));
    const receivedAtDrop = receiver.get(j.id)!.byId.get(f.id)!.received.count;
    expect(receivedAtDrop).toBeGreaterThan(0);

    const second = await link(receiver);
    transport.attach(second.sender);
    await j.done;
    expect(j.snapshot().state).toBe("complete");
    expect(j.snapshot().reconnects).toBe(1);
    // the second link carried only what was missing (plus framing and a little in-flight overlap)
    expect(second.sender.bytesSent).toBeLessThan(data.length - (receivedAtDrop - 4) * BLOCK_SIZE + 64 * 1024);
    const t = receiver.get(j.id)!;
    const got = await receiver.file(t, t.byId.get(f.id)!);
    expect(Buffer.compare(Buffer.from(await got.arrayBuffer()), Buffer.from(data))).toBe(0);
  });

  it("keeps the send buffer bounded on a slow link (backpressure), never overflowing the channel", async () => {
    const { receiver } = setup();
    const high = 256 * 1024;
    const { sender } = await link(receiver, { rate: 30, sendQueueLimit: 2 << 20 }, high);
    const j = job(new PeerTransport(sender), [source("v.mov", bytes(8 * BLOCK_SIZE, 7))]);
    await j.start();
    await j.done;
    expect(j.snapshot().state).toBe("complete");
    // data never crosses the mark; control frames (a few hundred bytes) skip the wait
    expect(sender.peakBuffered).toBeLessThanOrEqual(high + 4096);
    expect(j.telemetry().peakInflightBytes).toBeLessThanOrEqual(PEER_CONTROLLER.memoryBudget);
  });

  it("resumes on a reloaded receiver page from its saved state", async () => {
    const { receiver, sinks, state } = setup();
    const first = await link(receiver, { rate: 20 });
    const data = bytes(10 * BLOCK_SIZE, 9);
    const f = source("r.bin", data);
    const transport = new PeerTransport(first.sender);
    const j = job(transport, [f]);
    await j.start();
    while (j.snapshot().bytesDone < 3 * BLOCK_SIZE) await new Promise((r) => setTimeout(r, 5));
    await new Promise((r) => setTimeout(r, 1100)); // debounced persist
    first.cut();

    // "reload": a new receiver over the same storage, no memory of the transfer
    let asked = 0;
    const reloaded = new PeerReceiver({ sinks, state, accept: async () => (asked++, true) });
    const second = await link(reloaded);
    transport.attach(second.sender);
    await j.done;
    expect(j.snapshot().state).toBe("complete");
    expect(asked).toBe(0); // already accepted before the reload
    const t = reloaded.get(j.id)!;
    const got = await reloaded.file(t, t.byId.get(f.id)!);
    expect(Buffer.compare(Buffer.from(await got.arrayBuffer()), Buffer.from(data))).toBe(0);
  });

  it("packs 1,000 small files into a few batch frames, each stored in one hand-off", async () => {
    const { receiver, sinks } = setup();
    const { sender } = await link(receiver, { rate: 2000 });
    const files = Array.from({ length: 1000 }, (_, i) => source(`p/${i}.txt`, bytes(10_000, 100 + i), "notes"));
    const j = job(new PeerTransport(sender), files);
    await j.start();
    await j.done;
    expect(j.snapshot().state).toBe("complete");
    // 10 MB in ≤ 8 MiB frames: a handful of requests, not 1,000
    expect(j.telemetry().requests).toBeLessThan(20);
    expect(sinks.batchWrites).toBe(j.telemetry().requests);
    const got = await sinks.file(j.id, files[637]!.id, "x", "");
    expect(Buffer.compare(Buffer.from(await got.arrayBuffer()), Buffer.from(bytes(10_000, 737)))).toBe(0);
  });

  it("aborts a request mid-body without desynchronising the channel, then resumes", async () => {
    const { receiver } = setup();
    const { sender } = await link(receiver, { rate: 15 });
    const data = bytes(12 * BLOCK_SIZE, 11);
    const f = source("pause.mov", data);
    const j = job(new PeerTransport(sender), [f]);
    await j.start();
    while (j.snapshot().bytesDone < 2 * BLOCK_SIZE) await new Promise((r) => setTimeout(r, 5));
    j.pause(); // aborts in-flight requests, some of them mid-body
    await new Promise((r) => setTimeout(r, 300));
    j.resume();
    await j.done;
    expect(j.snapshot().state).toBe("complete");
    expect(j.snapshot().chunkFailures).toBe(0);
    const t = receiver.get(j.id)!;
    const got = await receiver.file(t, t.byId.get(f.id)!);
    expect(Buffer.compare(Buffer.from(await got.arrayBuffer()), Buffer.from(data))).toBe(0);
  });

  it("sends file bytes as raw binary messages: no per-frame header, no JSON, no base64", async () => {
    const { receiver } = setup();
    const frames: Uint8Array[] = [];
    const { sender } = await link(receiver, { tamper: (fr) => (frames.push(fr), fr) });
    const data = bytes(2 * BLOCK_SIZE + 5, 13);
    const j = job(new PeerTransport(sender), [source("raw.bin", data)]);
    await j.start();
    await j.done;
    const total = frames.reduce((s, fr) => s + fr.byteLength, 0);
    expect(total).toBe(data.byteLength);
    expect(Buffer.compare(Buffer.from(frames[0]!), Buffer.from(data.subarray(0, frames[0]!.byteLength)))).toBe(0);
  });

  it("refuses PC-direction manifests", async () => {
    const { receiver } = setup();
    const { sender } = await link(receiver);
    const j = new TransferJob({ transport: new PeerTransport(sender), files: [source("a", bytes(10))], direction: "to-host", label: "x" });
    await j.start();
    await j.done;
    expect(j.snapshot().errorCode).toBe("FORBIDDEN");
  });
});

describe("signaling payload", () => {
  it("round-trips compressed and fits a QR", async () => {
    const sdp = `v=0\r\no=- 46117317 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\na=candidate:1 1 udp 2122260223 192.168.1.23 54321 typ host generation 0\r\na=candidate:2 1 udp 2122260223 fd00::1 54322 typ host generation 0\r\na=ice-ufrag:abcd\r\na=ice-pwd:0123456789abcdefghijklmn\r\na=fingerprint:sha-256 ${"AB:".repeat(31)}AB\r\na=setup:actpass\r\na=mid:0\r\na=sctp-port:5000\r\na=max-message-size:262144\r\n`;
    const enc = await encodeSignal({ v: 2, type: "offer", sdp, sid: "0123456789abcdef01", name: "Ved's iPhone" });
    expect(enc.length).toBeLessThan(900);
    expect((await decodeSignal(`https://drop.example/p2p.html#o=${enc}&k=AAAAAAAAAAAAAAAAAAAAAA`)).sdp).toBe(sdp);
    expect(extractSignal("hello")).toBeNull();
    await expect(decodeSignal("Dnot-valid")).rejects.toThrow();
  });
});

describe("network path", () => {
  it("only claims local when the addresses prove it", () => {
    expect(isLocalAddress("192.168.1.4")).toBe(true);
    expect(isLocalAddress("172.20.10.2")).toBe(true); // iPhone hotspot
    expect(isLocalAddress("abc123.local")).toBe(true);
    expect(isLocalAddress("fe80::1")).toBe(true);
    expect(isLocalAddress("8.8.8.8")).toBe(false);
    expect(isLocalAddress("100.64.1.1")).toBe(false);
    const host = (address: string) => ({ type: "host" as const, address, protocol: "udp" });
    expect(classifyPath(host("192.168.1.4"), host("192.168.1.9")).kind).toBe("local");
    expect(classifyPath(host("2001:db8:1:2::5"), { type: "prflx", address: "2001:db8:1:2::9", protocol: "udp" }).kind).toBe("local");
    expect(classifyPath({ type: "srflx", address: "81.2.3.4", protocol: "udp" }, host("192.168.1.9")).kind).toBe("p2p");
    expect(classifyPath({ type: "relay", address: "10.0.0.1", protocol: "udp" }, host("10.0.0.2")).kind).toBe("relayed");
    expect(classifyPath(null, null).kind).toBe("unknown");
  });

  it("reads the selected pair from getStats output (Chrome and Safari shapes)", () => {
    const chrome = [
      { id: "T1", type: "transport", selectedCandidatePairId: "P1" },
      { id: "P1", type: "candidate-pair", state: "succeeded", localCandidateId: "L", remoteCandidateId: "R", currentRoundTripTime: 0.004 },
      { id: "L", type: "local-candidate", candidateType: "host", address: "192.168.0.10", protocol: "udp" },
      { id: "R", type: "remote-candidate", candidateType: "prflx", address: "192.168.0.11", protocol: "udp" },
    ];
    const p = pathFromStats(chrome);
    expect(p.kind).toBe("local");
    expect(p.rttMs).toBe(4);
    const safari = [
      { id: "P9", type: "candidate-pair", state: "succeeded", nominated: true, localCandidateId: "L", remoteCandidateId: "R" },
      { id: "L", type: "local-candidate", candidateType: "srflx", address: "81.1.1.1", protocol: "udp" },
      { id: "R", type: "remote-candidate", candidateType: "host", address: "10.1.1.1", protocol: "udp" },
    ];
    expect(pathFromStats(safari).kind).toBe("p2p");
  });
});
