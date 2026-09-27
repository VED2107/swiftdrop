/**
 * Rolling-window throughput meter.
 *
 * Chunks land in lumps (a 16 MiB request completes all at once), so instantaneous
 * rates are noise. We sum bytes over a sliding window and divide by the window span,
 * which gives a stable, monotone-decaying reading the UI can show without jitter.
 */
export class SpeedMeter {
  private readonly windowMs: number;
  private readonly now: () => number;
  private times: number[] = [];
  private amounts: number[] = [];
  private head = 0;
  private windowSum = 0;
  private startedAt = -1;
  private activeMs = 0;
  private resumedAt = -1;
  total = 0;
  peak = 0;

  constructor(windowMs = 3000, now: () => number = () => performance.now()) {
    this.windowMs = windowMs;
    this.now = now;
  }

  /** Marks the meter active (time counts toward the average). */
  start(): void {
    const t = this.now();
    if (this.startedAt < 0) this.startedAt = t;
    if (this.resumedAt < 0) this.resumedAt = t;
  }

  /** Marks the meter idle (paused, reconnecting) so the average stays honest. */
  stop(): void {
    if (this.resumedAt >= 0) {
      this.activeMs += this.now() - this.resumedAt;
      this.resumedAt = -1;
    }
    this.clearWindow();
  }

  add(bytes: number): void {
    const t = this.now();
    this.times.push(t);
    this.amounts.push(bytes);
    this.windowSum += bytes;
    this.total += bytes;
  }

  /** Bytes/second over the rolling window. Also updates `peak`. */
  rate(): number {
    const t = this.now();
    this.prune(t);
    if (this.resumedAt < 0) return 0;
    const span = Math.max(500, Math.min(this.windowMs, t - this.resumedAt));
    const r = (this.windowSum * 1000) / span;
    // Peak ignores the first moments of a run, when one early chunk can fake a spike.
    if (t - this.resumedAt >= Math.min(this.windowMs, 1500) && r > this.peak) this.peak = r;
    return r;
  }

  /** Average over active time only. */
  average(): number {
    const active = this.activeMs + (this.resumedAt >= 0 ? this.now() - this.resumedAt : 0);
    return active > 0 ? (this.total * 1000) / active : 0;
  }

  get activeSeconds(): number {
    return (this.activeMs + (this.resumedAt >= 0 ? this.now() - this.resumedAt : 0)) / 1000;
  }

  private prune(t: number): void {
    const cutoff = t - this.windowMs;
    while (this.head < this.times.length && this.times[this.head]! <= cutoff) {
      this.windowSum -= this.amounts[this.head]!;
      this.head++;
    }
    if (this.head > 1024) {
      this.times = this.times.slice(this.head);
      this.amounts = this.amounts.slice(this.head);
      this.head = 0;
    }
  }

  private clearWindow(): void {
    this.times = [];
    this.amounts = [];
    this.head = 0;
    this.windowSum = 0;
  }
}
