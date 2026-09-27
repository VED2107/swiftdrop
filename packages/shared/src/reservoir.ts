/** Fixed-size ring of recent values; percentiles over what's in it. */
export class Reservoir {
  private readonly buf: Float64Array;
  private n = 0;
  private i = 0;
  constructor(size = 512) {
    this.buf = new Float64Array(size);
  }
  add(v: number) {
    this.buf[this.i] = v;
    this.i = (this.i + 1) % this.buf.length;
    if (this.n < this.buf.length) this.n++;
  }
  get count() {
    return this.n;
  }
  percentile(p: number): number {
    if (this.n === 0) return 0;
    const sorted = Array.from(this.buf.subarray(0, this.n)).sort((a, b) => a - b);
    return sorted[Math.min(this.n - 1, Math.floor((p / 100) * this.n))]!;
  }
  clear() {
    this.n = 0;
    this.i = 0;
  }
}
