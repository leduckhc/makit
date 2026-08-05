/**
 * Pure byte/frame counters for WebSocket traffic.
 *
 * `addIn`/`addOut`/`frame` accumulate; `sampleRates` converts the accumulators
 * to per-second rates over the interval since the previous call, then resets.
 * Byte counts are taken from the already-serialized frame at the transport — no
 * second `JSON.stringify` for accounting.
 */
export class WireMeter {
  private inBytes = 0;
  private outBytes = 0;
  private frames = 0;
  /** Wall time of the previous `sampleRates` call, or null before the first. */
  private lastSampleAt: number | null = null;

  addIn(bytes: number): void {
    this.inBytes += bytes;
  }

  addOut(bytes: number): void {
    this.outBytes += bytes;
  }

  frame(): void {
    this.frames += 1;
  }

  sampleRates(now: number): {
    inBytesPerSec: number;
    outBytesPerSec: number;
    /**
     * Frames per second, NOT a per-window count. A raw count would jump 5x at the
     * 5s-to-1Hz cadence seam while the byte rates stayed smooth, so every field
     * here is normalised the same way.
     */
    framesPerSec: number;
  } {
    const elapsedMs = this.lastSampleAt === null ? 0 : now - this.lastSampleAt;
    // A zero-or-negative window has no meaningful rate; report 0 rather than
    // dividing by zero.
    const perSec = (total: number) =>
      elapsedMs > 0 ? (total * 1000) / elapsedMs : 0;

    const result = {
      inBytesPerSec: perSec(this.inBytes),
      outBytesPerSec: perSec(this.outBytes),
      framesPerSec: perSec(this.frames),
    };

    this.inBytes = 0;
    this.outBytes = 0;
    this.frames = 0;
    this.lastSampleAt = now;
    return result;
  }
}
