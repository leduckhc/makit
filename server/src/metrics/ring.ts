/**
 * Fixed-size ring buffer for time-stamped samples.
 *
 * Backed by a pre-allocated array plus a write cursor so `push` is O(1) — no
 * `Array.shift`, whose O(n)-per-tick cost is exactly what this feature exists to
 * avoid. `toArray` and `sinceMs` return oldest-first.
 */
export class Ring<T extends { ts: number }> {
  private readonly buf: (T | undefined)[];
  private readonly capacity: number;
  /** Index of the next write slot. */
  private cursor = 0;
  /** Number of live items (<= capacity). */
  private size = 0;

  constructor(capacity: number) {
    this.capacity = Math.max(0, Math.floor(capacity));
    this.buf = new Array<T | undefined>(this.capacity);
  }

  push(v: T): void {
    if (this.capacity === 0) return;
    this.buf[this.cursor] = v;
    this.cursor = (this.cursor + 1) % this.capacity;
    if (this.size < this.capacity) this.size++;
  }

  /** All live items, oldest first. */
  toArray(): T[] {
    const out: T[] = [];
    // Oldest item sits `size` slots behind the cursor.
    const start = (this.cursor - this.size + this.capacity) % (this.capacity || 1);
    for (let i = 0; i < this.size; i++) {
      const item = this.buf[(start + i) % this.capacity];
      if (item !== undefined) out.push(item);
    }
    return out;
  }

  /**
   * Items with `ts >= now - ms`, oldest first.
   *
   * The boundary is **inclusive**: a sample whose `ts` equals `now - ms`
   * exactly is returned.
   */
  sinceMs(now: number, ms: number): T[] {
    const cutoff = now - ms;
    return this.toArray().filter((item) => item.ts >= cutoff);
  }
}
