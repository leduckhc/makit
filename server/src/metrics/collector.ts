/**
 * collector.ts — the one stateful piece of the metrics subsystem (SPEC-37 T5).
 *
 * Everything is injected (timers, clock, exec, the self/wire probes, the agent
 * list, storage stat, the app pid, the cpu-usage reader and the sink) so the
 * whole file is testable with fake timers and a literal exec — no subprocess is
 * ever spawned in a test. It owns cadence, the sample ring, per-pid CPU-rate
 * baselines and sample assembly.
 *
 * Locked decisions honoured here:
 *  - #2  cpuPercent is `null` (never `0`) until a rate is computable: on the
 *        first tick after `start()`, and on the first tick a given pid is seen.
 *  - #5  1 Hz while watched, 5 s while idle; nothing is ever persisted.
 *  - #10 the sampler reports its **own** CPU cost, measured around the tick.
 *  - #11 sessions with no pid are omitted, not zeroed.
 *
 * NOTE: the DTO types (`SurfaceDTO`, `AgentMetricsDTO`, `MetricsSampleDTO`) now
 * live in `server/src/protocol.ts` — that is where the wire contract lives, next
 * to the `github.budget` event. They are re-exported below so existing importers
 * of `collector.js` keep working, but the source of truth is `protocol.ts`.
 */

import {
  childIndex,
  descendants,
  sumTree,
  type ProcLike,
} from "./tree.js";
import { readProcTable, type Exec, type ProcRow } from "./proc_table.js";
import { Ring } from "./ring.js";
import type { SelfSample } from "./self.js";
import type {
  SurfaceDTO,
  AgentMetricsDTO,
  MetricsSampleDTO,
} from "../protocol.js";

// The wire contract lives in protocol.ts (next to `github.budget`); re-export
// so `collector.js` importers do not have to know where it moved.
export type { SurfaceDTO, AgentMetricsDTO, MetricsSampleDTO } from "../protocol.js";

// ---------------------------------------------------------------------------
// Injected shapes.
// ---------------------------------------------------------------------------

/** Opaque timer handle — production passes `setInterval`/`clearInterval`. */
export type TimerHandle = unknown;

/** The subset of a `monitorEventLoopDelay`-backed probe the collector needs. */
export interface SelfLike {
  sample(): SelfSample;
}

export interface WireLike {
  sampleRates(now: number): {
    inBytesPerSec: number;
    outBytesPerSec: number;
    framesPerSec: number;
  };
}

/**
 * Structural view of `CpuLedger` (churn-proof per-root CPU seconds). Declared
 * here rather than importing the concrete class so tests can inject a scripted
 * ledger — and note it is **not** strictly monotonic: its pid-reuse guard can
 * drop a frozen credit, so the total can legitimately fall (see `rateFor`).
 */
export interface LedgerLike {
  observe(root: number, pids: number[], table: Map<number, ProcRow>): number;
}

/** One live agent, as read from the manager via a closure (no manager import). */
export interface AgentEntry {
  sessionId: string;
  label: string;
  pid: number | undefined;
  inTurn: boolean;
}

/** Cumulative CPU usage in microseconds — same shape as `process.cpuUsage()`. */
export interface CpuUsageSnapshot {
  user: number;
  system: number;
}

export interface MetricsCollectorDeps {
  exec: Exec;
  now: () => number;
  setTimer: (fn: () => void, ms: number) => TimerHandle;
  clearTimer: (handle: TimerHandle) => void;
  self: SelfLike;
  wire: WireLike;
  ledger: LedgerLike;
  agents: () => AgentEntry[];
  storage: () => Promise<{ eventLogBytes: number }>;
  appPid: () => number | undefined;
  /** Cumulative CPU usage of this process; injected so self-cost is testable. */
  cpuUsage: () => CpuUsageSnapshot;
  /** Sink for each assembled sample. `coarse` is true on idle-cadence frames. */
  onSample: (sample: MetricsSampleDTO, meta: { coarse: boolean }) => void;
  watchedIntervalMs: number;
  idleIntervalMs: number;
  ringCapacity: number;
}

// ---------------------------------------------------------------------------
// Constants.
// ---------------------------------------------------------------------------

/**
 * `ps` timeout. Chosen at 800 ms: comfortably above a healthy `ps` (tens of ms)
 * yet below the 1 s watched cadence, so a wedged `ps` is abandoned before the
 * next tick fires and ticks cannot pile up (decision 5's "must not distort").
 */
const PS_TIMEOUT_MS = 800;

/** Storage (event-log size) is a steady-state value, refreshed every 6th tick. */
const STORAGE_EVERY = 6;

/** 30 minutes of history is handed to each newly-subscribed watcher. */
const HISTORY_WINDOW_MS = 30 * 60_000;

const MS_PER_SEC = 1000;
const MICROS_PER_SEC = 1_000_000;
const MICROS_PER_MS = 1000;
const PERCENT = 100;

interface CpuBaseline {
  cpuSeconds: number;
  wallMs: number;
}

export class MetricsCollector {
  private readonly deps: MetricsCollectorDeps;
  private readonly ring: Ring<MetricsSampleDTO>;

  private handle: TimerHandle | null = null;
  private running = false;
  /** The interval the live timer was armed with; null when no timer is armed. */
  private currentIntervalMs: number | null = null;
  private watchers = 0;

  private tickCount = 0;
  /** True while a tick is in flight — see {@link onTick} for why overlap is refused. */
  private ticking = false;

  /**
   * Wall clock at the previous tick's start — the denominator for the sampler's
   * own CPU rate. The tick's execution span is NOT the right denominator: the
   * honest question is "what fraction of a wall second does measuring cost?",
   * and dividing by the tick's own duration answers "what fraction of the tick
   * was busy" (~always large), overstating the meter's cost by interval/span.
   */
  private lastTickStartMs: number | null = null;
  /** Per-pid CPU baseline for the Δcpu ÷ Δwall rate (app + every agent). */
  private readonly cpuBaseline = new Map<number, CpuBaseline>();
  /** First wall time a pid was observed, for `uptimeMs`. */
  private readonly firstSeenMs = new Map<number, number>();
  /** Log a tick failure once per contiguous failure streak, not at 1 Hz. */
  private errorLogged = false;

  constructor(deps: MetricsCollectorDeps) {
    this.deps = deps;
    this.ring = new Ring<MetricsSampleDTO>(deps.ringCapacity);
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    // A restart has no baselines: the next tick's rates are `null` (decision 2).
    this.cpuBaseline.clear();
    this.firstSeenMs.clear();
    // Including the sampler's own baseline. Leaving it set divided the next
    // tick's CPU by an interval spanning the entire stopped gap, so the meter
    // reported a fabricated near-zero cost for its first post-restart sample.
    this.lastTickStartMs = null;
    this.arm(this.intervalForWatchers());
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.handle !== null) this.deps.clearTimer(this.handle);
    this.handle = null;
    this.currentIntervalMs = null;
  }

  /**
   * Set the number of watching clients. Picks the watched cadence when >0 and
   * the idle cadence otherwise, but **re-arms the timer only when the interval
   * actually changes** — otherwise a client toggling watch would reset the
   * timer's phase on every call.
   */
  setWatchers(n: number): void {
    this.watchers = n;
    if (!this.running) return;
    const interval = this.intervalForWatchers();
    if (interval !== this.currentIntervalMs) this.arm(interval);
  }

  /** History for a freshly-subscribed watcher: the last 30 minutes of samples. */
  /** Pids with retained rate state — for tests asserting the absence of a leak. */
  get trackedPidCount(): number {
    return this.cpuBaseline.size;
  }

  historyFor(now: number): MetricsSampleDTO[] {
    return this.ring.sinceMs(now, HISTORY_WINDOW_MS);
  }

  private intervalForWatchers(): number {
    return this.watchers > 0
      ? this.deps.watchedIntervalMs
      : this.deps.idleIntervalMs;
  }

  private arm(interval: number): void {
    if (this.handle !== null) this.deps.clearTimer(this.handle);
    this.currentIntervalMs = interval;
    this.handle = this.deps.setTimer(this.onTick, interval);
  }

  /**
   * Timer callback. A tick that throws (missing `ps`, a rejecting `exec`, a
   * storage stat failure) is logged once and swallowed so the timer stays
   * alive — a silently dead collector is worse than a gap in the chart.
   *
   * Returns the promise so tests can await it; production (`setInterval`)
   * ignores the return value.
   */
  private readonly onTick = async (): Promise<void> => {
    // `setInterval` does not await an async callback, and the 800ms `ps` cap bounds
    // only the exec — not the self probe, the fs.stat, or assembly. Under event-loop
    // congestion (exactly when these numbers matter) a tick can outlive its interval,
    // and two overlapping ticks would race on the CPU baselines and interleave their
    // `cpuUsage()` reads, producing a garbage `sampler` figure. Skip instead.
    if (this.ticking) return;
    this.ticking = true;
    try {
      await this.tick();
      this.errorLogged = false;
    } catch (err) {
      if (!this.errorLogged) {
        this.errorLogged = true;
        console.error("[metrics] collector tick failed; timer kept alive", err);
      }
    } finally {
      this.ticking = false;
    }
  };

  private async tick(): Promise<void> {
    const coarse = this.watchers === 0;
    const cpuBefore = this.deps.cpuUsage();
    const nowMs = this.deps.now();

    // One `ps` for the whole machine, with a timeout so a wedged `ps` cannot
    // pile up ticks. `readProcTable` calls exec with an undefined timeout, so we
    // wrap it to supply the bound. NOTE: readProcTable may reject — that is why
    // the whole tick runs under onTick's guard.
    const timedExec: Exec = (cmd, args, cwd, timeoutMs) =>
      this.deps.exec(cmd, args, cwd, timeoutMs ?? PS_TIMEOUT_MS);
    const { ok: procTableOk, table } = await readProcTable(timedExec);

    // Build the ppid index ONCE and reuse it for every root (decision 3).
    const index = childIndex(table);

    const agentEntries = this.deps.agents();
    // With no process table there is nothing honest to say about any agent: a row
    // of zeros reads as "idle" and an omitted row reads as "exited", so we omit the
    // rows and let `procTableOk` carry the reason (see MetricsSampleDTO).
    const agents = procTableOk
      ? agentEntries
          .filter((a): a is AgentEntry & { pid: number } => a.pid !== undefined)
          .map((a) => this.assembleAgent(a, table, index, nowMs, coarse))
      : [];

    const appPid = this.deps.appPid();
    const app =
      appPid === undefined || !procTableOk
        ? null
        : this.assembleSurface(appPid, table, index, nowMs);

    const selfSample = this.deps.self.sample();
    const wire = this.deps.wire.sampleRates(nowMs);

    const storage = await this.readStorage();

    const cpuAfter = this.deps.cpuUsage();

    const sample: MetricsSampleDTO = {
      ts: nowMs,
      app,
      server: {
        pid: process.pid,
        rssBytes: selfSample.rssBytes,
        // self.ts derives this from a cpuUsage() delta that can go backwards;
        // clamp at the boundary so the dashboard never shows a negative CPU%.
        cpuPercent:
          selfSample.cpuPercent === null
            ? null
            : Math.max(0, selfSample.cpuPercent),
        cpuSeconds: (cpuAfter.user + cpuAfter.system) / MICROS_PER_SEC,
        eventLoop: {
          p50: selfSample.loopDelayP50Ms,
          p99: selfSample.loopDelayP99Ms,
        },
      },
      agents,
      wire,
      storage,
      sampler: {
        cpuPercent: this.samplerCpuPercent(
          cpuBefore,
          cpuAfter,
          this.lastTickStartMs,
          nowMs,
        ),
        // Deliberately null: see MetricsSampleDTO.sampler. The server's resident
        // size is already the `server` row; repeating it here as "our own cost"
        // was the panel's one dishonest number.
        rssBytes: null,
      },
      // Derived from the full closure: a session mid-turn matters for the icon
      // even if it has no pid (and is therefore absent from `agents`).
      turnActive: agentEntries.some((a) => a.inTurn),
      procTableOk,
    };

    this.tickCount++;
    // Advance the sampler's rate baseline. Set from the tick's START instant, not
    // its end, so consecutive baselines are exactly one interval apart and the
    // tick's own duration never leaks into the denominator.
    this.lastTickStartMs = nowMs;
    // Prune the per-pid rate state to the pids we still care about. `cpuBaseline`
    // and `firstSeenMs` would otherwise grow one entry per distinct root pid ever
    // seen, for the lifetime of the server — a slow leak in the feature that claims
    // makit is cheap (the same defect decision 4 forbids for the ledger, which
    // server.ts already prunes).
    const livePids = new Set<number>(agentEntries.map((a) => a.pid).filter((p): p is number => p !== undefined));
    if (appPid !== undefined) livePids.add(appPid);
    for (const pid of this.cpuBaseline.keys()) if (!livePids.has(pid)) this.cpuBaseline.delete(pid);
    for (const pid of this.firstSeenMs.keys()) if (!livePids.has(pid)) this.firstSeenMs.delete(pid);

    this.ring.push(sample);
    this.deps.onSample(sample, { coarse });
  }

  private assembleAgent(
    entry: AgentEntry & { pid: number },
    table: Map<number, ProcRow>,
    index: Map<number, number[]>,
    nowMs: number,
    coarse: boolean,
  ): AgentMetricsDTO {
    const surface = this.assembleSurface(entry.pid, table, index, nowMs);
    const agent: AgentMetricsDTO = {
      ...surface,
      sessionId: entry.sessionId,
      label: entry.label,
      inTurn: entry.inTurn,
    };
    if (!coarse) {
      const totals = sumTree(table, index, entry.pid);
      agent.procs = totals.procs;
      agent.uptimeMs = this.uptimeFor(entry.pid, nowMs);
    }
    return agent;
  }

  private assembleSurface(
    pid: number,
    table: Map<number, ProcLike>,
    index: Map<number, number[]>,
    nowMs: number,
  ): SurfaceDTO {
    const totals = sumTree(table, index, pid);
    const pids = descendants(index, pid);
    const cpuSeconds = this.deps.ledger.observe(pid, pids, table);
    return {
      pid,
      rssBytes: totals.rssBytes,
      cpuPercent: this.rateFor(pid, cpuSeconds, nowMs),
      cpuSeconds,
    };
  }

  /**
   * Δcpu ÷ Δwall as a percentage. `null` — never `0` — when there is no prior
   * baseline for this pid (first tick after start, or first sighting of a pid)
   * or when wall time did not advance. This is decision 2, the most important
   * behaviour in the file.
   */
  private rateFor(pid: number, cpuSeconds: number, nowMs: number): number | null {
    const prev = this.cpuBaseline.get(pid);
    let cpuPercent: number | null = null;
    if (prev) {
      const dWallMs = nowMs - prev.wallMs;
      if (dWallMs > 0) {
        // The ledger is not strictly monotonic (pid-reuse drops a frozen
        // credit), so clamp Δcpu at zero: a falling total is 0%, never a
        // negative CPU% on the dashboard.
        const dCpuSeconds = Math.max(0, cpuSeconds - prev.cpuSeconds);
        cpuPercent = (dCpuSeconds / (dWallMs / MS_PER_SEC)) * PERCENT;
      }
    }
    this.cpuBaseline.set(pid, { cpuSeconds, wallMs: nowMs });
    return cpuPercent;
  }

  private uptimeFor(pid: number, nowMs: number): number {
    const first = this.firstSeenMs.get(pid);
    if (first === undefined) {
      this.firstSeenMs.set(pid, nowMs);
      return 0;
    }
    return nowMs - first;
  }

  /**
   * The sampler's own cost: CPU consumed *by this tick* over the wall time since
   * the *previous* tick. `null` on the first tick — a rate needs two points
   * (decision 2), and a fabricated 0 would read as "measuring is free".
   */
  private samplerCpuPercent(
    before: CpuUsageSnapshot,
    after: CpuUsageSnapshot,
    prevTickStartMs: number | null,
    tickStartMs: number,
  ): number | null {
    if (prevTickStartMs === null) return null;
    const dWallMs = tickStartMs - prevTickStartMs;
    if (dWallMs <= 0) return null;
    const dCpuMicros = after.user - before.user + (after.system - before.system);
    return (dCpuMicros / (dWallMs * MICROS_PER_MS)) * PERCENT;
  }

  private async readStorage(): Promise<{ eventLogBytes: number } | null> {
    if (this.tickCount % STORAGE_EVERY !== 0) return null;
    try {
      return await this.deps.storage();
    } catch {
      // A stat failure blanks storage for this tick, not the whole sample; the
      // app keeps the last value it saw.
      return null;
    }
  }
}
