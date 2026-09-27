import type { TransferJob } from "./job.ts";

/**
 * Runs jobs one at a time. Two transfers racing for the same Wi-Fi link just split it
 * and double the per-request overhead, so queued jobs wait their turn.
 */
export class TransferQueue {
  private readonly jobs: TransferJob[] = [];
  private readonly listeners = new Set<() => void>();
  private active: TransferJob | null = null;

  add(job: TransferJob): void {
    this.jobs.push(job);
    job.onChange(() => {
      this.emit();
      this.advance();
    });
    this.emit();
    this.advance();
  }

  remove(job: TransferJob): void {
    const i = this.jobs.indexOf(job);
    if (i >= 0) this.jobs.splice(i, 1);
    this.emit();
  }

  clearFinished(): void {
    for (let i = this.jobs.length - 1; i >= 0; i--) {
      const s = this.jobs[i]!.state;
      if (s === "complete" || s === "cancelled") this.jobs.splice(i, 1);
    }
    this.emit();
  }

  list(): readonly TransferJob[] {
    return this.jobs;
  }

  get current(): TransferJob | null {
    return this.active;
  }

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private advance() {
    const busy = this.jobs.find((j) => ["preparing", "awaiting-decision", "running", "reconnecting"].includes(j.state));
    if (busy) {
      this.active = busy;
      return;
    }
    const next = this.jobs.find((j) => j.state === "queued");
    this.active = next ?? this.jobs.find((j) => j.state === "paused") ?? null;
    if (next) void next.start();
  }

  private emit() {
    for (const fn of this.listeners) fn();
  }
}
