import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { BLOCK_SIZE } from "@swiftdrop/protocol";
import { HttpTransport, TransferJob, TransportError, type Transport } from "@swiftdrop/transfer-engine";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { bytes, cleanup, guestTransport, pairGuest, source, startServer, type TestServer } from "./helpers.ts";

let s: TestServer;
let token: string;

beforeAll(async () => {
  s = await startServer();
  token = await pairGuest(s);
});
afterAll(async () => {
  await s.stop();
  await cleanup(s);
});

const fastSampling = { sampleIntervalMs: 100 };

describe("iPhone -> PC transfer", () => {
  it("moves large, small, empty and nested files byte-for-byte", async () => {
    const big = bytes(5 * BLOCK_SIZE + 12345, 1);
    const huge = bytes(17 * BLOCK_SIZE + 7, 2);
    const smalls = Array.from({ length: 60 }, (_, i) => source(`IMG_${1000 + i}.JPG`, bytes(1000 + i * 37, 10 + i), "DCIM/100APPLE"));
    const files = [source("VID_0001.MOV", big), source("archive.zip", huge), source("empty.txt", new Uint8Array(0)), ...smalls];

    const job = new TransferJob({ transport: guestTransport(s, token), files, direction: "to-host", label: "Photos", ...fastSampling });
    await job.start();
    await job.done;
    const snap = job.snapshot();
    expect(snap.state).toBe("complete");
    expect(snap.filesDone).toBe(files.length);
    expect(snap.bytesDone).toBe(snap.bytesTotal);

    expect(Buffer.compare(await readFile(join(s.dirs.dest, "VID_0001.MOV")), Buffer.from(big))).toBe(0);
    expect(Buffer.compare(await readFile(join(s.dirs.dest, "archive.zip")), Buffer.from(huge))).toBe(0);
    expect((await stat(join(s.dirs.dest, "empty.txt"))).size).toBe(0);
    const img = await readFile(join(s.dirs.dest, "DCIM", "100APPLE", "IMG_1005.JPG"));
    expect(Buffer.compare(img, Buffer.from(bytes(1000 + 5 * 37, 15)))).toBe(0);
    // arrivals keep today's date so they sort to the top in Explorer
    expect(Date.now() - (await stat(join(s.dirs.dest, "VID_0001.MOV"))).mtimeMs).toBeLessThan(60_000);
    // bookkeeping for a finished transfer is gone
    expect(await stat(join(s.dirs.dest, ".swiftdrop", `${job.id}.json`)).catch(() => null)).toBeNull();
  });

  it("confines hostile names to the destination folder", async () => {
    const files = [source("..\\..\\evil.txt", bytes(10, 3), "../../outside"), source("CON", bytes(10, 4))];
    const job = new TransferJob({ transport: guestTransport(s, token), files, direction: "to-host", label: "x", onConflict: "keep-both" });
    await job.start();
    await job.done;
    expect(job.snapshot().state).toBe("complete");
    expect((await stat(join(s.dirs.dest, "outside", ".._.._evil.txt"))).isFile()).toBe(true);
    expect((await stat(join(s.dirs.dest, "_CON"))).isFile()).toBe(true);
  });

  it("survives a network drop mid-transfer and only resends what's missing", async () => {
    const data = bytes(24 * BLOCK_SIZE, 5);
    const inner = guestTransport(s, token);
    let puts = 0;
    let sentBytes = 0;
    let outage = false;
    const flaky: Transport = {
      ...bind(inner),
      async putBlocks(tid, fid, start, body, hashes, signal) {
        puts++;
        if (puts === 4) {
          outage = true;
          setTimeout(() => (outage = false), 300);
        }
        if (outage) throw new TransportError("NETWORK");
        sentBytes += body.byteLength;
        return inner.putBlocks(tid, fid, start, body, hashes, signal);
      },
      async ping() {
        if (outage) throw new TransportError("NETWORK");
        return inner.ping();
      },
    };
    const job = new TransferJob({ transport: flaky, files: [source("resume.bin", data)], direction: "to-host", label: "r", ...fastSampling });
    await job.start();
    await job.done;
    const snap = job.snapshot();
    expect(snap.state).toBe("complete");
    expect(snap.reconnects).toBeGreaterThanOrEqual(1);
    expect(sentBytes).toBeLessThan(data.byteLength * 1.5);
    expect(Buffer.compare(await readFile(join(s.dirs.dest, "resume.bin")), Buffer.from(data))).toBe(0);
  });

  it("resumes an interrupted transfer in a new session without resending finished blocks", async () => {
    const data = bytes(20 * BLOCK_SIZE, 6);
    const file = source("session.bin", data);
    let firstSession = 0;
    const inner = guestTransport(s, token);
    const counting: Transport = {
      ...bind(inner),
      async putBlocks(...args) {
        firstSession += args[3].byteLength;
        return inner.putBlocks(...args);
      },
    };
    const job1 = new TransferJob({ transport: counting, files: [file], direction: "to-host", label: "s", controller: tinyController() });
    await job1.start();
    while (job1.snapshot().bytesDone < 8 * BLOCK_SIZE) await new Promise((r) => setTimeout(r, 5));
    job1.pause();
    // page reload: a fresh job with the same transfer id and the same file
    let secondSession = 0;
    const counting2: Transport = {
      ...bind(inner),
      async putBlocks(...args) {
        secondSession += args[3].byteLength;
        return inner.putBlocks(...args);
      },
    };
    const job2 = new TransferJob({ transport: counting2, files: [file], transferId: job1.id, direction: "to-host", label: "s", controller: tinyController() });
    await job2.start();
    await job2.done;
    expect(job2.snapshot().state).toBe("complete");
    expect(secondSession).toBeLessThan(data.byteLength - 6 * BLOCK_SIZE);
    expect(Buffer.compare(await readFile(join(s.dirs.dest, "session.bin")), Buffer.from(data))).toBe(0);
  });

  it("detects corrupted chunks and resends them", async () => {
    const data = bytes(6 * BLOCK_SIZE, 7);
    const inner = guestTransport(s, token);
    let corrupted = false;
    const evil: Transport = {
      ...bind(inner),
      async putBlocks(tid, fid, start, body, hashes, signal) {
        if (!corrupted && start > 0) {
          corrupted = true;
          const bad = body.slice();
          bad[100] = bad[100]! ^ 0xff;
          return inner.putBlocks(tid, fid, start, bad, hashes, signal);
        }
        return inner.putBlocks(tid, fid, start, body, hashes, signal);
      },
    };
    const job = new TransferJob({ transport: evil, files: [source("corrupt.bin", data)], direction: "to-host", label: "c" });
    await job.start();
    await job.done;
    expect(job.snapshot().state).toBe("complete");
    expect(job.snapshot().chunkFailures).toBeGreaterThanOrEqual(1);
    expect(Buffer.compare(await readFile(join(s.dirs.dest, "corrupt.bin")), Buffer.from(data))).toBe(0);
  });

  it("restarts a file whose source changed between sessions (root mismatch)", async () => {
    const original = bytes(4 * BLOCK_SIZE, 8);
    const f1 = source("changed.bin", original);
    const job1 = new TransferJob({ transport: guestTransport(s, token), files: [f1], direction: "to-host", label: "m", controller: tinyController() });
    await job1.start();
    while (job1.snapshot().bytesDone < 2 * BLOCK_SIZE) await new Promise((r) => setTimeout(r, 5));
    job1.pause();
    const edited = bytes(4 * BLOCK_SIZE, 9); // same size, different content
    const f2 = { ...f1, blob: new Blob([edited]) };
    const job2 = new TransferJob({ transport: guestTransport(s, token), files: [f2], transferId: job1.id, direction: "to-host", label: "m" });
    await job2.start();
    await job2.done;
    expect(job2.snapshot().state).toBe("complete");
    expect(Buffer.compare(await readFile(join(s.dirs.dest, "changed.bin")), Buffer.from(edited))).toBe(0);
  });
});

describe("duplicates", () => {
  it("asks, then keeps both or skips per decision", async () => {
    await mkdir(s.dirs.dest, { recursive: true });
    await writeFile(join(s.dirs.dest, "dup.jpg"), "existing");
    await writeFile(join(s.dirs.dest, "dup2.jpg"), "existing");
    const a = source("dup.jpg", bytes(2000, 11));
    const b = source("dup2.jpg", bytes(2000, 12));
    let asked = 0;
    const job = new TransferJob({
      transport: guestTransport(s, token),
      files: [a, b],
      direction: "to-host",
      label: "d",
      resolveConflicts: async (conflicts) => {
        asked = conflicts.length;
        return { [a.id]: "keep-both", [b.id]: "skip" };
      },
    });
    await job.start();
    await job.done;
    expect(asked).toBe(2);
    expect(job.snapshot().filesSkipped).toBe(1);
    expect(await readFile(join(s.dirs.dest, "dup.jpg"), "utf8")).toBe("existing");
    expect((await readFile(join(s.dirs.dest, "dup (1).jpg"))).length).toBe(2000);
    expect(await readFile(join(s.dirs.dest, "dup2.jpg"), "utf8")).toBe("existing");
  });

  it("finds clashes in nested folders, ignores same-named folders, respects the OS's case rules", async () => {
    await mkdir(join(s.dirs.dest, "Album", "sub.jpg"), { recursive: true }); // a folder, not a file
    await writeFile(join(s.dirs.dest, "Album", "photo.jpg"), "existing");
    const clash = source(process.platform === "linux" ? "photo.jpg" : "PHOTO.JPG", bytes(100, 13), "Album");
    const folderNamed = source("sub.jpg", bytes(100, 14), "Album");
    const fresh = Array.from({ length: 50 }, (_, i) => source(`new_${i}.jpg`, bytes(100, 100 + i), "Album"));
    let asked: string[] = [];
    const job = new TransferJob({
      transport: guestTransport(s, token),
      files: [clash, folderNamed, ...fresh],
      direction: "to-host",
      label: "n",
      resolveConflicts: async (conflicts) => {
        asked = conflicts.map((c) => c.name);
        return { [clash.id]: "skip" };
      },
    });
    await job.start();
    await job.done;
    expect(asked).toEqual([`Album/${clash.name}`]);
    expect(job.snapshot().filesSkipped).toBe(1);
  });
});

describe("security", () => {
  it("rejects unauthenticated data writes and host-only routes", async () => {
    const put = await fetch(`${s.base}/api/transfers/tr_abcdefgh/files/file_000001/blocks/0`, { method: "PUT", body: "x" });
    expect(put.status).toBe(401);
    const bogus = await fetch(`${s.base}/api/transfers`, { method: "POST", headers: { authorization: "Bearer nope" }, body: "{}" });
    expect(bogus.status).toBe(401);
    const hostOnly = await fetch(`${s.base}/api/host/pairing`, { headers: { authorization: `Bearer ${token}` } });
    expect(hostOnly.status).toBe(403);
  });

  it("rejects cross-origin writes and foreign Host headers", async () => {
    const res = await fetch(`${s.base}/api/join`, {
      method: "POST",
      headers: { origin: "http://evil.example", "content-type": "application/json" },
      body: JSON.stringify({ code: "AAAAAA", deviceName: "x" }),
    });
    expect(res.status).toBe(403);
    const http = await import("node:http");
    const status = await new Promise<number>((resolve) => {
      const url = new URL(s.base);
      http.get({ host: url.hostname, port: url.port, path: "/api/ping", headers: { host: "attacker.example" } }, (r) => resolve(r.statusCode ?? 0));
    });
    expect(status).toBe(421);
  });

  it("rate-limits pairing code guesses", async () => {
    const statuses: number[] = [];
    for (let i = 0; i < 9; i++) {
      const r = await fetch(`${s.base}/api/join`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ code: "ZZZZZZ", deviceName: "guesser" }),
      });
      statuses.push(r.status);
    }
    expect(statuses).toContain(429);
  });

  it("guests cannot push to the outbox", async () => {
    const job = new TransferJob({ transport: guestTransport(s, token), files: [source("a.bin", bytes(10))], direction: "to-guest", label: "x" });
    await job.start();
    await job.done;
    expect(job.snapshot().errorCode).toBe("FORBIDDEN");
  });
});

describe("PC -> iPhone", () => {
  it("stages an offer and serves ranged downloads and a valid ZIP", async () => {
    const hostTransport = new HttpTransport({
      baseUrl: s.base,
      fetch: (input, init) => fetch(input, { ...init, headers: { ...(init?.headers as Record<string, string>), "x-test-role": "host" } }),
    });
    const one = bytes(3 * BLOCK_SIZE + 5, 20);
    const two = bytes(4000, 21);
    const job = new TransferJob({
      transport: hostTransport,
      files: [source("movie.mp4", one), source("notes.txt", two, "docs")],
      direction: "to-guest",
      label: "For phone",
    });
    await job.start();
    await job.done;
    expect(job.snapshot().state).toBe("complete");

    const auth = { authorization: `Bearer ${token}` };
    const { offers } = (await (await fetch(`${s.base}/api/offers`, { headers: auth })).json()) as {
      offers: Array<{ transferId: string; files: Array<{ id: string; name: string }> }>;
    };
    const offer = offers.find((o) => o.transferId === job.id)!;
    expect(offer.files.map((f) => f.name)).toEqual(["movie.mp4", "notes.txt"]);

    // ticketed plain download (what Safari navigation uses)
    const { ticket } = (await (await fetch(`${s.base}/api/offers/${job.id}/ticket`, { method: "POST", headers: auth })).json()) as { ticket: string };
    const fileUrl = `${s.base}/api/offers/${job.id}/files/${offer.files[0]!.id}`;
    expect((await fetch(fileUrl)).status).toBe(401);
    const full = await fetch(`${fileUrl}?ticket=${encodeURIComponent(ticket)}`);
    expect(full.headers.get("content-disposition")).toContain("movie.mp4");
    expect(Buffer.compare(Buffer.from(await full.arrayBuffer()), Buffer.from(one))).toBe(0);
    const part = await fetch(`${fileUrl}?ticket=${encodeURIComponent(ticket)}`, { headers: { range: "bytes=100-199" } });
    expect(part.status).toBe(206);
    expect(Buffer.compare(Buffer.from(await part.arrayBuffer()), Buffer.from(one.subarray(100, 200)))).toBe(0);

    const zipRes = await fetch(`${s.base}/api/offers/${job.id}/zip?ticket=${encodeURIComponent(ticket)}`);
    const zip = Buffer.from(await zipRes.arrayBuffer());
    expect(Number(zipRes.headers.get("content-length"))).toBe(zip.length);
    const entries = await unzip(zip);
    expect(Buffer.compare(entries.get("movie.mp4")!, Buffer.from(one))).toBe(0);
    expect(Buffer.compare(entries.get("docs/notes.txt")!, Buffer.from(two))).toBe(0);
  });
});

describe("PC -> iPhone from local files (no staging)", () => {
  it("serves picked files and folders in place, refuses changed sources, never deletes originals", async () => {
    const src = join(s.dirs.root, "pc-files");
    await mkdir(join(src, "Trip", "day 1"), { recursive: true });
    const movie = bytes(3 * BLOCK_SIZE + 99, 40);
    const photo = bytes(70_000, 41);
    await writeFile(join(src, "movie.mp4"), movie);
    await writeFile(join(src, "Trip", "day 1", "IMG_1.JPG"), photo);
    await writeFile(join(src, "Trip", "Thumbs.db"), bytes(10, 42));

    const guest = await fetch(`${s.base}/api/host/offers/paths`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ paths: [join(src, "movie.mp4")] }),
    });
    expect(guest.status).toBe(403);

    const res = await s.hostFetch("/api/host/offers/paths", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ paths: [join(src, "movie.mp4"), join(src, "Trip")] }),
    });
    expect(res.status).toBe(200);
    const { offer } = (await res.json()) as { offer: { transferId: string; totalBytes: number; files: Array<{ id: string; name: string; relDir: string; type: string }> } };
    expect(offer.files.map((f) => [f.relDir, f.name])).toEqual([
      ["", "movie.mp4"],
      ["Trip/day 1", "IMG_1.JPG"],
    ]);
    expect(offer.files[0]!.type).toBe("video/mp4");
    expect(offer.totalBytes).toBe(movie.length + photo.length);
    // nothing was copied into the outbox
    expect(await stat(join(s.dirs.outbox, offer.transferId, offer.files[0]!.id)).catch(() => null)).toBeNull();

    const auth = { authorization: `Bearer ${token}` };
    const { ticket } = (await (await fetch(`${s.base}/api/offers/${offer.transferId}/ticket`, { method: "POST", headers: auth })).json()) as { ticket: string };
    const q = `?ticket=${encodeURIComponent(ticket)}`;
    const one = await fetch(`${s.base}/api/offers/${offer.transferId}/files/${offer.files[0]!.id}${q}`);
    expect(Buffer.compare(Buffer.from(await one.arrayBuffer()), Buffer.from(movie))).toBe(0);
    const tail = await fetch(`${s.base}/api/offers/${offer.transferId}/files/${offer.files[0]!.id}${q}`, { headers: { range: "bytes=-50" } });
    expect(Buffer.compare(Buffer.from(await tail.arrayBuffer()), Buffer.from(movie.subarray(movie.length - 50)))).toBe(0);
    const zip = await unzip(Buffer.from(await (await fetch(`${s.base}/api/offers/${offer.transferId}/zip${q}`)).arrayBuffer()));
    expect(Buffer.compare(zip.get("Trip/day 1/IMG_1.JPG")!, Buffer.from(photo))).toBe(0);

    // edited after sharing: refuse instead of sending different bytes under the old size
    await writeFile(join(src, "Trip", "day 1", "IMG_1.JPG"), bytes(70_001, 43));
    const stale = await fetch(`${s.base}/api/offers/${offer.transferId}/files/${offer.files[1]!.id}${q}`);
    expect(stale.status).toBe(410);
    expect(((await stale.json()) as { code: string }).code).toBe("SOURCE_CHANGED");
    expect((await fetch(`${s.base}/api/offers/${offer.transferId}/zip${q}`)).status).toBe(410);

    // withdrawing the offer leaves the PC's own files alone
    expect((await s.hostFetch(`/api/offers/${offer.transferId}`, { method: "DELETE" })).status).toBe(200);
    expect((await stat(join(src, "movie.mp4"))).size).toBe(movie.length);
    expect((await stat(join(src, "Trip", "day 1", "IMG_1.JPG"))).isFile()).toBe(true);
  });
});

describe("server restart", () => {
  it("keeps pairing and resumes a transfer after the PC app restarts", async () => {
    const data = bytes(12 * BLOCK_SIZE, 30);
    const file = source("restart.bin", data);
    const job1 = new TransferJob({ transport: guestTransport(s, token), files: [file], direction: "to-host", label: "rs", controller: tinyController() });
    await job1.start();
    while (job1.snapshot().bytesDone < 4 * BLOCK_SIZE) await new Promise((r) => setTimeout(r, 5));
    job1.pause();
    const port = Number(new URL(s.base).port);
    await s.stop();
    s = await startServer({ root: s.dirs.root, port });
    const job2 = new TransferJob({ transport: guestTransport(s, token), files: [file], transferId: job1.id, direction: "to-host", label: "rs" });
    await job2.start();
    await job2.done;
    expect(job2.snapshot().state).toBe("complete");
    expect(Buffer.compare(await readFile(join(s.dirs.dest, "restart.bin")), Buffer.from(data))).toBe(0);
  });
});

// ---------------------------------------------------------------------------

function bind(t: HttpTransport): Transport {
  return {
    create: t.create.bind(t),
    status: t.status.bind(t),
    putBlocks: t.putBlocks.bind(t),
    putBatch: t.putBatch.bind(t),
    complete: t.complete.bind(t),
    cancel: t.cancel.bind(t),
    ping: t.ping.bind(t),
  };
}

/** One stream, one block per request: makes mid-transfer interruption points deterministic. */
function tinyController() {
  return {
    minStreams: 1,
    maxStreams: 1,
    initialStreams: 1,
    minBlocks: 1,
    maxBlocks: 1,
    initialBlocks: 1,
    blockSize: BLOCK_SIZE,
    memoryBudget: 64 << 20,
    targetLatencyMs: [250, 900] as [number, number],
    gainThreshold: 0.05,
    holdSamples: 10,
    minCompletions: 6,
    maxWindowSamples: 4,
    settleSamples: 1,
  };
}

async function unzip(buf: Buffer): Promise<Map<string, Buffer>> {
  const yauzl = await import("yauzl");
  return new Promise((resolve, reject) => {
    yauzl.fromBuffer(buf, { lazyEntries: true }, (err, zip) => {
      if (err || !zip) return reject(err);
      const out = new Map<string, Buffer>();
      zip.on("entry", (entry: import("yauzl").Entry) => {
        zip.openReadStream(entry, (e, stream) => {
          if (e || !stream) return reject(e);
          const chunks: Buffer[] = [];
          stream.on("data", (c: Buffer) => chunks.push(c));
          stream.on("end", () => {
            out.set(entry.fileName, Buffer.concat(chunks));
            zip.readEntry();
          });
        });
      });
      zip.on("end", () => resolve(out));
      zip.readEntry();
    });
  });
}
