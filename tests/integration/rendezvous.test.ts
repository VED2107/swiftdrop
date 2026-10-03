import type { AddressInfo } from "node:net";
import { Mailbox, type MailMessage } from "@swiftdrop/peer";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createSignalServer } from "../../apps/signal/src/server.ts";

// One-QR pairing: the sender shows a QR (offer + mailbox secret), the scanning receiver's
// answer comes back through a rendezvous mailbox that only ever sees ciphertext.

const server = createSignalServer();
let base = "";
const posted: string[] = [];

beforeAll(async () => {
  server.on("request", (req) => {
    if (req.method !== "POST") return;
    let body = "";
    req.on("data", (c: Buffer) => (body += c.toString()));
    req.on("end", () => posted.push(body));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
afterAll(() => new Promise<void>((r) => server.close(() => r())));

function next(box: Mailbox, which: "host" | "guest"): { got: Promise<MailMessage>; stop: () => void } {
  let stop = () => {};
  const got = new Promise<MailMessage>((resolve) => {
    stop = box.listen(which, resolve);
  });
  return { got, stop };
}

describe("rendezvous mailbox", () => {
  it("delivers a sealed answer from the scanning phone to the phone showing the QR", async () => {
    const host = Mailbox.create(base);
    const listening = next(host, "host");
    // the sender only knows what the QR said
    const guest = Mailbox.fromKey(base, host.key);
    const answer = "Dsome-compressed-sdp-answer";
    await guest.post("host", { kind: "answer", signal: answer });
    expect(await listening.got).toEqual({ kind: "answer", signal: answer });
    listening.stop();
    // the server saw ciphertext only
    expect(posted.at(-1)).toMatch(/^1\.[A-Za-z0-9_-]+$/);
    expect(posted.at(-1)).not.toContain(answer);
  });

  it("delivers messages posted before the listener connected", async () => {
    const host = Mailbox.create(base);
    const guest = Mailbox.fromKey(base, host.key);
    await guest.post("host", { kind: "answer", signal: "Dearly" });
    const l = next(host, "host");
    expect((await l.got).signal).toBe("Dearly");
    l.stop();
  });

  it("ignores messages sealed with another secret (other QR, forged, tampered)", async () => {
    const host = Mailbox.create(base);
    const seen: MailMessage[] = [];
    const stop = host.listen("host", (m) => seen.push(m));
    // same topic name can't be computed without the secret; post garbage straight to every topic we know
    const stranger = Mailbox.create(base);
    await stranger.post("host", { kind: "answer", signal: "Dintruder" });
    const right = Mailbox.fromKey(base, host.key);
    await right.post("host", { kind: "answer", signal: "Dgood" });
    await new Promise((r) => setTimeout(r, 300));
    stop();
    expect(seen.map((m) => m.signal)).toEqual(["Dgood"]);
  });

  it("keeps the two directions apart (re-dial offers vs. their answers)", async () => {
    const host = Mailbox.create(base);
    const guest = Mailbox.fromKey(base, host.key);
    const toGuest = next(guest, "guest");
    const toHost = next(host, "host");
    await guest.post("host", { kind: "offer", signal: "Dredial" });
    await host.post("guest", { kind: "answer", signal: "Dreply" });
    expect((await toHost.got).signal).toBe("Dredial");
    expect((await toGuest.got).signal).toBe("Dreply");
    toGuest.stop();
    toHost.stop();
  });

  it("rejects bodies too large to be anything but signaling", async () => {
    const res = await fetch(`${base}/sdtest`, { method: "POST", body: "x".repeat(5000) });
    expect(res.status).toBe(413);
  });

  it.skipIf(!process.env.SD_NTFY)("works against ntfy.sh unchanged (SD_NTFY=1)", async () => {
    const host = Mailbox.create("https://ntfy.sh");
    const l = next(host, "host");
    await Mailbox.fromKey("https://ntfy.sh", host.key).post("host", { kind: "answer", signal: "Dntfy" });
    expect((await l.got).signal).toBe("Dntfy");
    l.stop();
  });
});
