import { BATCH_MAX_FILES, BATCH_TARGET_BYTES, SMALL_FILE_MAX, type TransferStatus } from "@swiftdrop/protocol";
import { Bitset } from "@swiftdrop/shared";

/**
 * Decides what to send next.
 *
 * Large files are cut into block ranges on demand (range length = the controller's
 * current chunk size), so parallel streams pull consecutive ranges of the same file
 * and the server writes them positionally. Small files are packed into batch frames
 * so 10,000 photos cost hundreds of requests, not 10,000.
 *
 * Every block is in one of three states: missing, claimed (in flight), acked.
 * Failures release the claim; nothing is ever re-sent once acked.
 */

export interface PlanFile {
  readonly index: number;
  readonly id: string;
  readonly size: number;
  readonly blocks: number;
  readonly small: boolean;
  state: "pending" | "complete" | "skipped" | "failed";
  acked: Bitset;
  claimed: Bitset;
  /** scan position for the next unclaimed block */
  cursor: number;
  /** integrity failures on this file; network failures don't count */
  strikes: number;
  /** true while a batch frame carrying this small file is in flight */
  inBatch: boolean;
  /** true while the completion (root hash check) request is in flight */
  completing: boolean;
  finalName?: string;
}

export type WorkItem =
  | { kind: "complete"; file: PlanFile }
  | { kind: "blocks"; file: PlanFile; start: number; count: number }
  | { kind: "batch"; files: PlanFile[]; bytes: number };

export class Planner {
  readonly blockSize: number;
  readonly files: PlanFile[];
  private largeCursor = 0;
  private smallCursor = 0;
  private flip = false;
  private readonly largeOrder: number[] = [];
  private readonly smallOrder: number[] = [];
  private toComplete: PlanFile[] = [];

  constructor(files: ReadonlyArray<{ id: string; size: number }>, blockSize: number) {
    this.blockSize = blockSize;
    this.files = files.map((f, index) => {
      const blocks = Math.ceil(f.size / blockSize);
      return {
        index,
        id: f.id,
        size: f.size,
        blocks,
        small: f.size <= SMALL_FILE_MAX,
        state: "pending",
        acked: new Bitset(blocks),
        claimed: new Bitset(blocks),
        cursor: 0,
        strikes: 0,
        inBatch: false,
        completing: false,
      } satisfies PlanFile;
    });
    for (const f of this.files) (f.small ? this.smallOrder : this.largeOrder).push(f.index);
  }

  /** Adopt the receiver's view (fresh create or resume after reconnect). Drops all claims. */
  applyStatus(status: TransferStatus): void {
    const byId = new Map(status.files.map((s) => [s.id, s]));
    for (const f of this.files) {
      const s = byId.get(f.id);
      f.claimed = new Bitset(f.blocks);
      f.cursor = 0;
      f.inBatch = false;
      f.completing = false;
      if (!s) continue;
      if (s.finalName) f.finalName = s.finalName;
      if (s.state === "complete") {
        f.state = "complete";
        f.acked = fullBitset(f.blocks);
      } else if (s.state === "skipped") {
        f.state = "skipped";
      } else if (f.state !== "failed") {
        f.state = "pending";
        f.acked = s.state === "partial" && s.received ? Bitset.fromBase64(f.blocks, s.received) : new Bitset(f.blocks);
      }
      // Claims mirror acks so the scanner skips acked blocks.
      for (let i = 0; i < f.blocks; i++) if (f.acked.has(i)) f.claimed.set(i);
    }
    this.largeCursor = 0;
    this.smallCursor = 0;
    // Everything received but never confirmed (e.g. the completion call was lost).
    this.toComplete = this.files.filter((f) => f.state === "pending" && !f.small && f.acked.complete);
  }

  next(blocksPerChunk: number): WorkItem | null {
    const done = this.toComplete.shift();
    if (done) {
      done.completing = true;
      return { kind: "complete", file: done };
    }
    // Alternate so a folder of mixed sizes shows progress on both fronts.
    this.flip = !this.flip;
    const first = this.flip ? this.nextBatch(blocksPerChunk) : this.nextRange(blocksPerChunk);
    if (first) return first;
    return this.flip ? this.nextRange(blocksPerChunk) : this.nextBatch(blocksPerChunk);
  }

  private nextRange(blocksPerChunk: number): WorkItem | null {
    for (let k = this.largeCursor; k < this.largeOrder.length; k++) {
      const f = this.files[this.largeOrder[k]!]!;
      if (f.state !== "pending") {
        if (k === this.largeCursor) this.largeCursor++;
        continue;
      }
      while (f.cursor < f.blocks && f.claimed.has(f.cursor)) f.cursor++;
      if (f.cursor >= f.blocks) continue; // fully claimed, waiting on acks
      const start = f.cursor;
      let count = 0;
      while (count < blocksPerChunk && start + count < f.blocks && !f.claimed.has(start + count)) {
        f.claimed.set(start + count);
        count++;
      }
      f.cursor = start + count;
      return { kind: "blocks", file: f, start, count };
    }
    return null;
  }

  private nextBatch(blocksPerChunk: number): WorkItem | null {
    const limit = Math.min(BATCH_TARGET_BYTES, Math.max(1, blocksPerChunk) * this.blockSize);
    const picked: PlanFile[] = [];
    let bytes = 0;
    for (let k = this.smallCursor; k < this.smallOrder.length; k++) {
      const f = this.files[this.smallOrder[k]!]!;
      if (f.state !== "pending" || f.inBatch) {
        if (k === this.smallCursor && f.state !== "pending") this.smallCursor++;
        continue;
      }
      if (picked.length > 0 && (bytes + f.size > limit || picked.length >= BATCH_MAX_FILES)) break;
      f.inBatch = true;
      picked.push(f);
      bytes += f.size;
    }
    return picked.length ? { kind: "batch", files: picked, bytes } : null;
  }

  /** Request succeeded. Returns files that just became complete (batches) or ready to confirm. */
  ack(item: WorkItem): PlanFile[] {
    if (item.kind === "complete") {
      item.file.completing = false;
      item.file.state = "complete";
      return [item.file];
    }
    if (item.kind === "batch") {
      for (const f of item.files) {
        f.inBatch = false;
        f.state = "complete";
        for (let i = 0; i < f.blocks; i++) f.acked.set(i);
      }
      return item.files;
    }
    const f = item.file;
    for (let i = item.start; i < item.start + item.count; i++) f.acked.set(i);
    if (f.acked.complete && !f.completing && !this.toComplete.includes(f)) {
      this.toComplete.push(f);
      return [f];
    }
    return [];
  }

  /** Request failed: make its blocks available again. */
  release(item: WorkItem): void {
    if (item.kind === "complete") {
      item.file.completing = false;
      if (item.file.state === "pending") this.toComplete.push(item.file);
      return;
    }
    if (item.kind === "batch") {
      for (const f of item.files) f.inBatch = false;
      this.smallCursor = Math.min(this.smallCursor, ...item.files.map((f) => this.smallOrder.indexOf(f.index)));
      return;
    }
    const f = item.file;
    const fresh = new Bitset(f.blocks);
    for (let i = 0; i < f.blocks; i++) {
      const inItem = i >= item.start && i < item.start + item.count;
      if (f.claimed.has(i) && (!inItem || f.acked.has(i))) fresh.set(i);
    }
    f.claimed = fresh;
    f.cursor = Math.min(f.cursor, item.start);
    const pos = this.largeOrder.indexOf(f.index);
    if (pos >= 0) this.largeCursor = Math.min(this.largeCursor, pos);
  }

  /** Receiver rejected the whole file (e.g. root mismatch): start it over. */
  resetFile(f: PlanFile): void {
    this.toComplete = this.toComplete.filter((x) => x !== f);
    f.completing = false;
    f.acked = new Bitset(f.blocks);
    f.claimed = new Bitset(f.blocks);
    f.cursor = 0;
    f.state = "pending";
    const order = f.small ? this.smallOrder : this.largeOrder;
    const pos = order.indexOf(f.index);
    if (f.small) this.smallCursor = Math.min(this.smallCursor, pos);
    else this.largeCursor = Math.min(this.largeCursor, pos);
  }

  get finished(): boolean {
    return this.toComplete.length === 0 && this.files.every((f) => f.state !== "pending");
  }

  ackedBytes(f: PlanFile): number {
    if (f.state === "complete") return f.size;
    if (f.blocks === 0) return 0;
    let n = f.acked.count * this.blockSize;
    if (f.acked.has(f.blocks - 1)) n -= f.blocks * this.blockSize - f.size;
    return n;
  }
}

function fullBitset(n: number): Bitset {
  const b = new Bitset(n);
  for (let i = 0; i < n; i++) b.set(i);
  return b;
}
