/**
 * service.ts — the one stateful piece of the ports subsystem: cadence, the
 * cached snapshot, and the no-overlap / watch-gated lifecycle (spec §"Delivery:
 * watch-gated, never ambient").
 *
 * Everything is injected (exec, the health probe, the worktree/session sources,
 * the tailnet address, the clock and the timer) so the whole file is testable
 * with a fake clock and a literal exec — no `lsof`/`ps` is ever spawned in a
 * test. It imports NO manager and NO session type: `listSessionRoots` is a
 * supplied `() => Map<string, number>`, the honest phrasing of "the service
 * knows nothing about sessions".
 */

import type { PortDTO, PortHealthDTO, PortsSnapshotDTO } from "../protocol.js";
import type { Exec } from "./scan.js";
import { listListeners } from "./scan.js";
import { readProcs, readCwds, createRealpathResolver } from "./proc.js";
import type { ProcInfo } from "./proc.js";
import { cwdPidSet } from "./ancestors.js";
import { attribute } from "./attribute.js";
import { annotate } from "./derive.js";
import { upsertEntry, type PortHistory } from "./history_store.js";
import { log } from "../log.js";

/**
 * Poll cadence while watched: 4 s. Fast enough that a dev server that just came
 * up is noticed within a glance, slow enough that three `exec`s every tick are
 * negligible. Nothing runs at all while no client is watching.
 */
export const SCAN_INTERVAL_MS = 4_000;

/**
 * Per-exec timeout. A wedged `lsof` under a stalled network mount must not
 * outlive the scan interval and pile up ticks; 3 s leaves head-room for a slow
 * but live command. This is a PER-EXEC budget, and `doScan` runs three reads
 * sequentially (listener `lsof`, `ps`, cwd `lsof`), so the worst-case whole scan
 * is ~3× this (~9 s). That cannot pile up ticks regardless: `runScan` skips any
 * tick that fires while a scan is still in flight (no queue), so a slow scan
 * delays the next one rather than overlapping it.
 */
const EXEC_TIMEOUT_MS = 3_000;

/** The health probe surface the service drives (see health.ts). */
export interface HealthProbeLike {
  refresh(ports: PortDTO[]): Promise<void>;
  verdict(address: string, port: number): PortHealthDTO | undefined;
}

export interface PortsServiceDeps {
  exec: Exec;
  probe: HealthProbeLike;
  /** Absolute worktree paths from the cached repos snapshot (no git per scan). */
  listWorktreePaths: () => string[];
  /**
   * Worktree path → branch, from the cached repos snapshot. Feeds the port
   * history's `branch` so an orphan can later say "was <branch>" — supplied here
   * (like {@link listWorktreePaths}) so the service imports no git/repos type.
   */
  listWorktreeBranches: () => Map<string, string>;
  /**
   * Port-history store, INJECTED (like {@link exec}) so tests use an in-memory
   * fake and `server.ts` wires the real JSON-file functions. A throwing read must
   * not fail the scan — `scanOk` reflects the scan, not the store (D7).
   */
  loadHistory: () => PortHistory;
  saveHistory: (history: PortHistory) => void;
  /** Session id → agent root pid, supplied by the caller (no session import). */
  listSessionRoots: () => Map<string, number>;
  /**
   * The host's discovered tailnet address (spec D2). A pure, synchronous
   * provider — derived from the bind host, never a `tailscale` subprocess — so
   * it can be read on the scan path without risking an event-loop stall.
   * Memoised after the first call.
   */
  tailnetAddress: () => string | null;
  onSnapshot: (snapshot: PortsSnapshotDTO) => void;
  now: () => number;
  /** `setInterval`-shaped in production: fires repeatedly until cleared. */
  setTimer: (fn: () => void, ms: number) => unknown;
  clearTimer: (handle: unknown) => void;
  /** Memoised realpath resolver; defaults to a fresh one per service. */
  resolveReal?: (path: string) => string;
}

interface ScanOutcome {
  ports: PortDTO[];
  scanOk: boolean;
  scanError?: string;
  /** History to persist when this snapshot is actually broadcast (debounced). */
  historyToSave?: PortHistory;
}

export class PortsService {
  private readonly deps: PortsServiceDeps;
  private readonly resolveReal: (path: string) => string;

  private watchers = 0;
  private handle: unknown = null;
  /** True while a scan is in flight — a tick that overlaps one is skipped. */
  private scanning = false;
  /** Retained across a failed scan so the UI never blanks (spec: keep last good). */
  private lastGoodPorts: PortDTO[] = [];
  /** The latest published snapshot, handed to a freshly-arrived watcher. */
  private cached: PortsSnapshotDTO | undefined;
  /** Projection of the last broadcast, minus `scannedAt`, for identity dedup. */
  private lastProjection: string | undefined;
  /** Memoised tailnet address (undefined = not yet resolved).*/
  private tailnet: string | null | undefined = undefined;

  constructor(deps: PortsServiceDeps) {
    this.deps = deps;
    this.resolveReal = deps.resolveReal ?? createRealpathResolver();
  }

  /** The last published snapshot, or undefined before the first scan completes. */
  cachedSnapshot(): PortsSnapshotDTO | undefined {
    return this.cached;
  }

  /**
   * Set the number of watching clients. On the 0→1 edge the timer arms AND an
   * immediate scan runs (a freshly-mounted panel paints within one scan, not a
   * whole tick); on the 1→0 edge the timer disarms and no work happens at all.
   */
  setWatchers(n: number): void {
    const prev = this.watchers;
    this.watchers = n;
    if (prev === 0 && n > 0) {
      this.arm();
      void this.runScan();
    } else if (prev > 0 && n === 0) {
      this.disarm();
    }
  }

  /** Disarm on shutdown so the process can exit cleanly. */
  stop(): void {
    this.disarm();
  }

  private arm(): void {
    this.handle = this.deps.setTimer(() => void this.runScan(), SCAN_INTERVAL_MS);
  }

  private disarm(): void {
    if (this.handle !== null) {
      this.deps.clearTimer(this.handle);
      this.handle = null;
    }
  }

  /**
   * One scan, guarded against overlap: a tick that fires while a scan is in
   * flight returns immediately (no queue). A scan that completes after the last
   * watcher left publishes nothing, so it cannot re-arm a disarmed service.
   */
  private async runScan(): Promise<void> {
    if (this.scanning) return;
    this.scanning = true;
    try {
      const outcome = await this.doScan();
      if (this.watchers === 0) return; // last watcher left mid-scan → publish nothing

      const scannedAt = this.deps.now();
      const snapshot: PortsSnapshotDTO = {
        ports: outcome.ports,
        scannedAt,
        scanOk: outcome.scanOk,
      };
      if (outcome.scanError !== undefined) snapshot.scanError = outcome.scanError;

      // Skip a re-broadcast when nothing but the timestamp changed. The cache is
      // advanced ONLY when we actually broadcast, so a freshly-arrived watcher
      // (hydrated from `cachedSnapshot()`) can never be handed a snapshot the
      // existing watchers never received.
      //
      // `startedAt` is excluded from the projection (but NOT from the DTO — the UI
      // needs it): `ps` reports `etime` at one-second granularity while `now` is
      // per-scan, so `startedAt = now - elapsed` jitters by up to 1000 ms between
      // ticks even when nothing changed, and including it would defeat the dedup
      // on almost every tick. A process RESTART still re-broadcasts because it
      // changes the pid, which stays in the projection (finding 25).
      const projection = JSON.stringify({
        ports: outcome.ports.map(({ startedAt: _startedAt, ...rest }) => rest),
        scanOk: outcome.scanOk,
        scanError: outcome.scanError,
      });
      if (projection !== this.lastProjection) {
        this.lastProjection = projection;
        this.cached = snapshot;
        this.deps.onSnapshot(snapshot);
        // Persist the history only when we actually broadcast: an unchanged
        // projection means the steady-state scan does no disk I/O (D11).
        if (outcome.historyToSave !== undefined) this.deps.saveHistory(outcome.historyToSave);
      }

      // Health probes run AFTER publishing (stale-while-revalidate): the socket
      // facts are instant, the network op must never be on the return path. Its
      // verdicts land on the next tick. `refresh` never throws.
      if (outcome.scanOk) void this.deps.probe.refresh(outcome.ports);
    } finally {
      this.scanning = false;
    }
  }

  /** Resolve the tailnet address at most once, on the first scan that needs it. */
  private tailnetOnce(): string | null {
    if (this.tailnet === undefined) this.tailnet = this.deps.tailnetAddress();
    return this.tailnet;
  }

  /**
   * Run the three reads and attribute them. A failed listener scan, a failed
   * `ps`/cwd read, or any thrown error yields `scanOk:false` with the LAST GOOD
   * ports retained — a transient `lsof`/`ps` hiccup must not blank a populated
   * list (spec D7: the flag means the scanner's commands ran).
   */
  private async doScan(): Promise<ScanOutcome> {
    try {
      const scan = await listListeners(this.deps.exec, EXEC_TIMEOUT_MS);
      if (!scan.ok) {
        return { ports: this.lastGoodPorts, scanOk: false, scanError: scan.error };
      }

      const now = this.deps.now();
      const procsResult = await readProcs(this.deps.exec, now, EXEC_TIMEOUT_MS);
      // A failed `ps` means attribution would be blind; keep the last good ports
      // and tell the truth with scanOk:false (D7 — the flag means the commands ran).
      if (!procsResult.ok) {
        return { ports: this.lastGoodPorts, scanOk: false, scanError: procsResult.error };
      }
      const procs = procsResult.procs;

      const pidSet = cwdPidSet(scan.listeners.map((l) => l.pid), procs);
      const cwdsResult = await readCwds(this.deps.exec, [...pidSet], EXEC_TIMEOUT_MS);
      if (!cwdsResult.ok) {
        return { ports: this.lastGoodPorts, scanOk: false, scanError: cwdsResult.error };
      }
      const cwds = cwdsResult.cwds;

      const ports = attribute({
        listeners: scan.listeners,
        procs,
        cwds,
        worktreePaths: this.deps.listWorktreePaths(),
        sessionRoots: this.deps.listSessionRoots(),
        health: (address, port) => this.deps.probe.verdict(address, port),
        tailnetAddress: this.tailnetOnce(),
        resolveReal: this.resolveReal,
      });

      // Fold the port history in: record every owned port, then annotate orphans
      // and collisions from the (updated) history before publishing.
      const { annotated, historyToSave } = this.foldHistory(ports, procs, cwds, now);

      this.lastGoodPorts = annotated;
      return { ports: annotated, scanOk: true, historyToSave };
    } catch (err) {
      return {
        ports: this.lastGoodPorts,
        scanOk: false,
        scanError: `port scan failed: ${(err as Error).message}`,
      };
    }
  }

  /**
   * Record every owned port into the history and annotate orphans/collisions
   * from the updated history. Isolated in its own try/catch: a throwing store
   * degrades to the plain attributed ports with no annotation and no write,
   * leaving `scanOk` untouched (D7 — the flag means the scanner's commands ran).
   */
  private foldHistory(
    ports: PortDTO[],
    procs: Map<number, ProcInfo>,
    cwds: Map<number, string>,
    now: number,
  ): { annotated: PortDTO[]; historyToSave?: PortHistory } {
    try {
      const branches = this.deps.listWorktreeBranches();
      let history = this.deps.loadHistory();
      for (const port of ports) {
        if (port.worktreePath === undefined) continue;
        history = upsertEntry(history, {
          worktreePath: port.worktreePath,
          branch: branches.get(port.worktreePath),
          port: port.port,
          now,
        });
      }
      const annotated = annotate({
        ports,
        cwds,
        procs,
        history,
        activeWorktreePaths: this.deps.listWorktreePaths(),
        resolveReal: this.resolveReal,
        now,
      });
      return { annotated, historyToSave: history };
    } catch (err) {
      log.warn(`[makit] port history unavailable this scan: ${(err as Error).message}`);
      return { annotated: ports };
    }
  }
}
