/** Compact bitmap of received blocks. Serializes to base64 for the resume handshake. */
export class Bitset {
  readonly size: number;
  private readonly bits: Uint8Array;
  private setCount = 0;

  constructor(size: number, bytes?: Uint8Array) {
    this.size = size;
    this.bits = new Uint8Array(Math.ceil(size / 8));
    if (bytes) {
      this.bits.set(bytes.subarray(0, this.bits.length));
      const tail = size % 8;
      if (tail && this.bits.length) this.bits[this.bits.length - 1]! &= (1 << tail) - 1;
      for (const byte of this.bits) this.setCount += popcount(byte);
    }
  }

  has(i: number): boolean {
    return (this.bits[i >> 3]! & (1 << (i & 7))) !== 0;
  }

  set(i: number): boolean {
    if (i < 0 || i >= this.size || this.has(i)) return false;
    this.bits[i >> 3]! |= 1 << (i & 7);
    this.setCount++;
    return true;
  }

  get count(): number {
    return this.setCount;
  }

  get complete(): boolean {
    return this.setCount === this.size;
  }

  /** Contiguous runs of missing indices as [start, endExclusive]. */
  missingRuns(): Array<[number, number]> {
    const runs: Array<[number, number]> = [];
    let start = -1;
    for (let i = 0; i < this.size; i++) {
      const missing = !this.has(i);
      if (missing && start < 0) start = i;
      if (!missing && start >= 0) {
        runs.push([start, i]);
        start = -1;
      }
    }
    if (start >= 0) runs.push([start, this.size]);
    return runs;
  }

  toBase64(): string {
    let s = "";
    for (let i = 0; i < this.bits.length; i += 0x8000) {
      s += String.fromCharCode(...this.bits.subarray(i, i + 0x8000));
    }
    return btoa(s);
  }

  static fromBase64(size: number, b64: string): Bitset {
    const raw = atob(b64);
    const bytes = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return new Bitset(size, bytes);
  }
}

function popcount(b: number): number {
  b = b - ((b >> 1) & 0x55);
  b = (b & 0x33) + ((b >> 2) & 0x33);
  return (b + (b >> 4)) & 0x0f;
}
