import { createReadStream } from "node:fs";
import type { Writable } from "node:stream";
import * as zlib from "node:zlib";

/**
 * Streaming ZIP writer, STORE only (photos and videos are already compressed; deflate
 * would burn CPU for ~0% gain). ZIP64 when any size/offset crosses 4 GiB.
 *
 * Because entries are stored and sizes are known up front, the exact archive length
 * is computable before the first byte — Safari gets a Content-Length and can show
 * real progress. CRCs are computed while streaming and written in data descriptors.
 */

export interface ZipEntry {
  name: string; // forward-slash relative path, already sanitized
  path: string; // source on disk
  size: number;
  mtime: Date;
}

const U32 = 0xffffffff;

interface Planned {
  entry: ZipEntry;
  nameBytes: Buffer;
  offset: number;
  zip64: boolean;
  crc: number;
}

function plan(entries: ZipEntry[]) {
  let offset = 0;
  const planned: Planned[] = [];
  for (const entry of entries) {
    const nameBytes = Buffer.from(entry.name, "utf8");
    const zip64 = entry.size >= U32 || offset >= U32;
    planned.push({ entry, nameBytes, offset, zip64, crc: 0 });
    offset += 30 + nameBytes.length + (zip64 ? 20 : 0) + entry.size + (zip64 ? 24 : 16);
  }
  return { planned, dataEnd: offset };
}

function centralSize(p: Planned): number {
  const needs64 = p.zip64 || p.offset >= U32;
  return 46 + p.nameBytes.length + (needs64 ? 28 : 0);
}

export function zipLength(entries: ZipEntry[]): number {
  const { planned, dataEnd } = plan(entries);
  const cd = planned.reduce((s, p) => s + centralSize(p), 0);
  const needs64 = dataEnd >= U32 || planned.length >= 0xffff || planned.some((p) => p.zip64);
  return dataEnd + cd + (needs64 ? 56 + 20 : 0) + 22;
}

export async function writeZip(entries: ZipEntry[], out: Writable, onBytes?: (n: number) => void): Promise<void> {
  const { planned, dataEnd } = plan(entries);
  const write = (buf: Buffer) =>
    new Promise<void>((resolve, reject) => {
      onBytes?.(buf.length);
      if (out.write(buf)) resolve();
      else {
        const onDrain = () => {
          out.off("error", onError);
          resolve();
        };
        const onError = (e: Error) => {
          out.off("drain", onDrain);
          reject(e);
        };
        out.once("drain", onDrain);
        out.once("error", onError);
      }
    });

  for (const p of planned) {
    const { dosTime, dosDate } = dos(p.entry.mtime);
    const extra = p.zip64 ? Buffer.alloc(20) : Buffer.alloc(0);
    if (p.zip64) {
      extra.writeUInt16LE(0x0001, 0);
      extra.writeUInt16LE(16, 2); // sizes zero here; real ones are in the descriptor
    }
    const h = Buffer.alloc(30);
    h.writeUInt32LE(0x04034b50, 0);
    h.writeUInt16LE(p.zip64 ? 45 : 20, 4);
    h.writeUInt16LE(0x0808, 6); // data descriptor + UTF-8 names
    h.writeUInt16LE(0, 8); // stored
    h.writeUInt16LE(dosTime, 10);
    h.writeUInt16LE(dosDate, 12);
    h.writeUInt32LE(0, 14);
    h.writeUInt32LE(p.zip64 ? U32 : 0, 18);
    h.writeUInt32LE(p.zip64 ? U32 : 0, 22);
    h.writeUInt16LE(p.nameBytes.length, 26);
    h.writeUInt16LE(extra.length, 28);
    await write(Buffer.concat([h, p.nameBytes, extra]));

    let crc = 0;
    let seen = 0;
    const stream = createReadStream(p.entry.path, { highWaterMark: 1 << 20 });
    for await (const chunk of stream as AsyncIterable<Buffer>) {
      crc = crc32(chunk, crc);
      seen += chunk.length;
      await write(chunk);
    }
    if (seen !== p.entry.size) throw new Error(`size changed while zipping ${p.entry.name}`);
    p.crc = crc >>> 0;

    const d = Buffer.alloc(p.zip64 ? 24 : 16);
    d.writeUInt32LE(0x08074b50, 0);
    d.writeUInt32LE(p.crc, 4);
    if (p.zip64) {
      d.writeBigUInt64LE(BigInt(p.entry.size), 8);
      d.writeBigUInt64LE(BigInt(p.entry.size), 16);
    } else {
      d.writeUInt32LE(p.entry.size, 8);
      d.writeUInt32LE(p.entry.size, 12);
    }
    await write(d);
  }

  let cdSize = 0;
  for (const p of planned) {
    const { dosTime, dosDate } = dos(p.entry.mtime);
    const bigSize = p.entry.size >= U32;
    const bigOffset = p.offset >= U32;
    const needs64 = p.zip64 || bigOffset;
    const extra = Buffer.alloc(needs64 ? 28 : 0);
    if (needs64) {
      extra.writeUInt16LE(0x0001, 0);
      extra.writeUInt16LE(24, 2);
      extra.writeBigUInt64LE(BigInt(p.entry.size), 4);
      extra.writeBigUInt64LE(BigInt(p.entry.size), 12);
      extra.writeBigUInt64LE(BigInt(p.offset), 20);
    }
    const c = Buffer.alloc(46);
    c.writeUInt32LE(0x02014b50, 0);
    c.writeUInt16LE(0x033f, 4); // made by: unix, 6.3
    c.writeUInt16LE(needs64 ? 45 : 20, 6);
    c.writeUInt16LE(0x0808, 8);
    c.writeUInt16LE(0, 10);
    c.writeUInt16LE(dosTime, 12);
    c.writeUInt16LE(dosDate, 14);
    c.writeUInt32LE(p.crc, 16);
    c.writeUInt32LE(needs64 ? U32 : p.entry.size, 20);
    c.writeUInt32LE(needs64 ? U32 : p.entry.size, 24);
    c.writeUInt16LE(p.nameBytes.length, 28);
    c.writeUInt16LE(extra.length, 30);
    c.writeUInt16LE(0, 32);
    c.writeUInt16LE(0, 34);
    c.writeUInt16LE(0, 36);
    c.writeUInt32LE((0o100644 << 16) >>> 0, 38);
    c.writeUInt32LE(needs64 ? U32 : p.offset, 42);
    void bigSize;
    const rec = Buffer.concat([c, p.nameBytes, extra]);
    cdSize += rec.length;
    await write(rec);
  }

  const count = planned.length;
  const needs64 = dataEnd >= U32 || count >= 0xffff || planned.some((p) => p.zip64);
  if (needs64) {
    const z = Buffer.alloc(56);
    z.writeUInt32LE(0x06064b50, 0);
    z.writeBigUInt64LE(44n, 4);
    z.writeUInt16LE(45, 12);
    z.writeUInt16LE(45, 14);
    z.writeUInt32LE(0, 16);
    z.writeUInt32LE(0, 20);
    z.writeBigUInt64LE(BigInt(count), 24);
    z.writeBigUInt64LE(BigInt(count), 32);
    z.writeBigUInt64LE(BigInt(cdSize), 40);
    z.writeBigUInt64LE(BigInt(dataEnd), 48);
    const l = Buffer.alloc(20);
    l.writeUInt32LE(0x07064b50, 0);
    l.writeUInt32LE(0, 4);
    l.writeBigUInt64LE(BigInt(dataEnd + cdSize), 8);
    l.writeUInt32LE(1, 16);
    await write(Buffer.concat([z, l]));
  }
  const e = Buffer.alloc(22);
  e.writeUInt32LE(0x06054b50, 0);
  e.writeUInt16LE(Math.min(count, 0xffff), 8);
  e.writeUInt16LE(Math.min(count, 0xffff), 10);
  e.writeUInt32LE(Math.min(cdSize, U32), 12);
  e.writeUInt32LE(needs64 ? U32 : dataEnd, 16);
  await write(e);
}

function dos(d: Date) {
  const year = Math.max(1980, d.getFullYear());
  return {
    dosTime: (d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1),
    dosDate: ((year - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate(),
  };
}

// zlib.crc32 exists from Node 22.2 (native, fast). Fallback keeps older Node working.
const nativeCrc = (zlib as unknown as { crc32?: (data: Uint8Array, value?: number) => number }).crc32;
let table: Int32Array | null = null;
function crc32(buf: Uint8Array, prev: number): number {
  if (nativeCrc) return nativeCrc(buf, prev);
  if (!table) {
    table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  let c = ~prev;
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]!) & 0xff]! ^ (c >>> 8);
  return ~c >>> 0;
}
