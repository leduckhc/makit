import { monitorEventLoopDelay } from "node:perf_hooks";

/** CPU time snapshot in microseconds, matching `process.cpuUsage()`. */
export interface CpuUsageSnapshot {
  user: number;
  system: number;
}

/**
 * Minimal structural view of a `monitorEventLoopDelay` histogram — the only
 * members `SelfProbe` touches. Injecting this keeps tests free of real loop
 * timing and lets the collector own histogram lifetime.
 */
export interface DelayHistogram {
  /** Start recording. Called once for the process lifetime. */
  enable(): void;
  /** Clear accumulated samples so the next window starts fresh. */
  reset(): void;
  /** Percentile in **nanoseconds** (Node's native unit). */
  percentile(p: number): number;
}

export interface SelfSample {
  rssBytes: number;
  /** `null` — never `0` — until a rate is computable (decision 2). */
  cpuPercent: number | null;
  loopDelayP50Ms: number;
  loopDelayP99Ms: number;
}

export interface SelfProbeDeps {
  /** Wall clock in milliseconds. */
  now: () => number;
  /** Cumulative CPU usage in microseconds. */
  cpuUsage: () => CpuUsageSnapshot;
  /** Resident set size in bytes. */
  rss: () => number;
  histogram: DelayHistogram;
}

const MICROS_PER_MS = 1000;
const NS_PER_MS = 1_000_000;
const PERCENT = 100;

/**
 * Samples this process's own resource use without spawning `ps`.
 *
 * CPU% is a rate between two `sample()` calls, so the first sample — and any
 * sample where wall time did not advance — reports `null` rather than a
 * fabricated `0`. The event-loop histogram is reset after every read so each
 * sample describes only its own window; a lifetime histogram would flatten
 * every spike into noise.
 */
export class SelfProbe {
  private readonly deps: SelfProbeDeps;
  private lastCpu: CpuUsageSnapshot | null = null;
  private lastWallMs: number | null = null;

  constructor(deps: SelfProbeDeps) {
    this.deps = deps;
    this.deps.histogram.enable();
  }

  sample(): SelfSample {
    const nowMs = this.deps.now();
    const cpu = this.deps.cpuUsage();

    let cpuPercent: number | null = null;
    if (this.lastCpu !== null && this.lastWallMs !== null) {
      const wallMicros = (nowMs - this.lastWallMs) * MICROS_PER_MS;
      if (wallMicros > 0) {
        const cpuMicros =
          cpu.user - this.lastCpu.user + (cpu.system - this.lastCpu.system);
        cpuPercent = (cpuMicros / wallMicros) * PERCENT;
      }
    }
    this.lastCpu = cpu;
    this.lastWallMs = nowMs;

    const p50 = this.deps.histogram.percentile(50);
    const p99 = this.deps.histogram.percentile(99);
    this.deps.histogram.reset();

    return {
      rssBytes: this.deps.rss(),
      cpuPercent,
      loopDelayP50Ms: p50 / NS_PER_MS,
      loopDelayP99Ms: p99 / NS_PER_MS,
    };
  }
}

/** Production probe wired to real Node accessors and one live histogram. */
export function createSelfProbe(): SelfProbe {
  const histogram = monitorEventLoopDelay({ resolution: 10 });
  return new SelfProbe({
    now: () => performance.now(),
    cpuUsage: () => process.cpuUsage(),
    rss: () => process.memoryUsage.rss(),
    histogram,
  });
}
