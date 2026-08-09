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

import type {
  PortDTO,
  PortHealthDTO,
  PortKillOrphansResult,
  PortKillResult,
  PortKillTarget,
  PortsSnapshotDTO,
} from "../protocol.js";
import type { Exec } from "./scan.js";
import { listListeners } from "./scan.js";
import { readProcs, readCwds, createRealpathResolver } from "./proc.js";
import type { ProcInfo } from "./proc.js";
import { cwdPidSet, walkAncestors } from "./ancestors.js";
import { attribute } from "./attribute.js";
import { annotate } from "./derive.js";
import { upsertEntry, type PortHistory } from "./history_store.js";
import { createDockerReader, isDockerBackend, type DockerReader } from "./docker.js";
import { KILL_GRACE_MS, classifyKillTarget, type KillGuards } from "./kill.js";
import { isWatched, type WatchedPort } from "./watch_store.js";
import { PortDownDetector } from "./watch.js";
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

/**
 * How many extra times a POST-signal verification scan is retried while it comes
 * back unusable. Two is enough: the window is the few hundred milliseconds in
 * which the signalled process is mid-exit (see
 * {@link PortsService.classifyFreshAfterSignal}).
 */
const POST_SIGNAL_SCAN_RETRIES = 2;

/** Gap between those retries — long enough for an exiting process to be reaped. */
const POST_SIGNAL_RETRY_MS = 250;

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
  /**
   * TTL-cached `docker ps` reader (SPEC-42 D13). Defaults to one built over
   * {@link exec} and {@link now}, so the cache lives exactly as long as the
   * service; tests may inject their own.
   */
  readDocker?: DockerReader;
  /**
   * SPEC-43: this process's pid, refused (with its ancestors) by the kill
   * whitelist. Injected so a test can make the scripted scan's pid "ours".
   */
  serverPid?: number;
  /**
   * SPEC-43: how a signal is delivered. Defaults to `process.kill`; injected so
   * no test can ever signal a real process. May throw (`ESRCH`/`EPERM`) exactly
   * like `process.kill` does.
   */
  signal?: (pid: number, sig: NodeJS.Signals) => void;
  /** SPEC-43: the SIGTERM grace wait. Injected so tests do not spend 2 s. */
  sleep?: (ms: number) => Promise<void>;
  /**
   * SPEC-44 D7: the current watch list, read per scan so a toggle takes effect on
   * the very next snapshot. Injected (like {@link loadHistory}) so the service
   * depends on two function handles, not on a JSON file.
   */
  watchedPorts?: () => WatchedPort[];
  /**
   * SPEC-44 D8: a watched endpoint has been continuously down for the grace
   * window. Called at most once per outage; `server.ts` turns it into one push.
   */
  onPortDown?: (port: WatchedPort) => void;
}

interface ScanOutcome {
  ports: PortDTO[];
  scanOk: boolean;
  scanError?: string;
  /** History to persist when this snapshot is actually broadcast (debounced). */
  historyToSave?: PortHistory;
  /**
   * The process table this scan read, kept for the kill path only: the `refused_self`
   * guard needs makit's ancestor chain, and re-reading `ps` for it would be a
   * second whole-machine exec inside one kill.
   */
  procs?: Map<number, ProcInfo>;
}

export class PortsService {
  private readonly deps: PortsServiceDeps;
  private readonly resolveReal: (path: string) => string;
  private readonly readDocker: DockerReader;
  private readonly serverPid: number;
  private readonly signal: (pid: number, sig: NodeJS.Signals) => void;
  private readonly sleep: (ms: number) => Promise<void>;
  /** SPEC-44 D8: outage tracking, driven by the scan cadence (no timers of its own). */
  private readonly downDetector: PortDownDetector;

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
    this.readDocker = deps.readDocker ?? createDockerReader(deps.exec, deps.now);
    this.serverPid = deps.serverPid ?? process.pid;
    this.signal = deps.signal ?? ((pid, sig) => process.kill(pid, sig));
    this.sleep =
      deps.sleep ?? ((ms) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
    this.downDetector = new PortDownDetector({
      now: deps.now,
      onDown: (port) => deps.onPortDown?.(port),
    });
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

  /**
   * Run one scan now and broadcast it if anyone is watching. Used after a kill
   * actually released an endpoint, so every watching list drops the row within
   * the round-trip instead of up to {@link SCAN_INTERVAL_MS} later.
   */
  async rescanNow(): Promise<void> {
    await this.runScan();
  }

  /**
   * One fresh scan, returned to the caller — independent of who is watching.
   *
   * The published cache is only advanced when the service actually broadcasts
   * (which needs a watcher and a changed projection), so a capability decision
   * must never read it: a forward requested while no list is open would
   * otherwise see no snapshot at all and refuse for the wrong reason. This is the
   * same discipline the kill path follows.
   */
  async scanNow(): Promise<PortsSnapshotDTO> {
    const outcome = await this.doScan();
    const snapshot: PortsSnapshotDTO = {
      ports: outcome.ports,
      scannedAt: this.deps.now(),
      scanOk: outcome.scanOk,
    };
    if (outcome.scanError !== undefined) snapshot.scanError = outcome.scanError;
    return snapshot;
  }

  /**
   * Terminate the listener the user confirmed (SPEC-43 D1/D2).
   *
   * The sequence IS the safety property: fresh scan → whitelist → SIGTERM →
   * grace → **fresh scan + whitelist again** → at most one SIGKILL → fresh scan
   * to report honestly. Nothing here reads the cached snapshot, and every
   * refusal is a returned outcome rather than an exception, because each one has
   * its own sentence in the UI.
   */
  async killPort(target: PortKillTarget, opts: { deviceId?: string } = {}): Promise<PortKillResult> {
    const echo = { address: target.address, port: target.port };
    const sent: string[] = [];
    /**
     * D7: one audit line per attempt, on stderr, never in a session's event log
     * (a kill is a HOST event, the same rule `ports.snapshot` follows). Metadata
     * only — who asked, what was signalled, what happened.
     */
    const finish = (outcome: PortKillResult["outcome"]): PortKillResult => {
      const line =
        `[ports] kill ${target.address}:${target.port} pid=${target.pid} ` +
        `startedAt=${target.startedAt} device=${opts.deviceId ?? "-"} ` +
        `signals=${sent.length === 0 ? "none" : sent.join("+")} → ${outcome}`;
      if (outcome === "released" || outcome === "force-killed") log.info(line);
      else log.warn(line);
      return { outcome, ...echo };
    };

    const first = await this.classifyFresh(target);
    if (!first.signal) return finish(first.outcome);

    sent.push("SIGTERM");
    const term = this.trySignal(first.pid, "SIGTERM");
    // ESRCH: it exited between the scan and the signal — the user's intent is
    // satisfied. EPERM: another uid owns it; the OS, not a pre-check, is what
    // tells us (D2), and no escalation can change that answer.
    if (term === "gone") return finish("released");
    if (term === "denied") return finish("survived");

    await this.sleep(KILL_GRACE_MS);

    const second = await this.classifyFreshAfterSignal(target);
    if (!second.signal) {
      // A scan we could not run says nothing about the outcome; claiming
      // "released" there would be the one lie this whole spec is against.
      if (second.outcome === "scan_unavailable") return finish("scan_unavailable");
      // Anything else (`not_found`, `identity_mismatch`) means OUR process no
      // longer holds the endpoint — SIGTERM worked. Escalating now would send
      // SIGKILL to whatever took the port, which is exactly the pid-reuse bug.
      return finish("released");
    }

    sent.push("SIGKILL");
    const kill = this.trySignal(second.pid, "SIGKILL");
    if (kill === "gone") return finish("released");
    if (kill === "denied") return finish("survived");

    const third = await this.classifyFreshAfterSignal(target);
    if (!third.signal && third.outcome === "scan_unavailable") {
      return finish("scan_unavailable");
    }
    // Still the same process on the same endpoint after a SIGKILL: tell the user
    // to reach for a terminal instead of reporting a success they can disprove.
    return finish(third.signal ? "survived" : "force-killed");
  }

  /**
   * Kill every listener the current scan classifies as an orphan (SPEC-43 D5).
   *
   * N independent, individually re-verified kills — **not** an atomic batch. You
   * cannot roll back a signal, so the only honest contract is one result per
   * endpoint, and one endpoint that survives never stops the rest. The orphan
   * set is read from a fresh scan (never the cache); a failed scan yields an
   * empty list, because "we could not look" must not become "nothing to do" AND
   * must never become "kill whatever the cache remembered".
   */
  async killOrphans(opts: { deviceId?: string } = {}): Promise<PortKillOrphansResult> {
    const scan = await this.doScan();
    if (!scan.scanOk) return { results: [] };

    const targets: PortKillTarget[] = [];
    for (const port of scan.ports) {
      // `startedAt` is what makes the identity verifiable (D1): an orphan without
      // one is skipped rather than killed on a two-field match.
      if (port.orphan === undefined || port.startedAt === undefined) continue;
      targets.push({
        address: port.address,
        port: port.port,
        pid: port.pid,
        startedAt: port.startedAt,
      });
    }

    const results: PortKillResult[] = [];
    for (const target of targets) {
      // Sequential on purpose: each kill re-scans, and running N scans
      // concurrently would multiply the `lsof`/`ps` load of the one operation
      // most likely to be aimed at a machine that is already struggling.
      results.push(await this.killPort(target, opts));
    }
    return { results };
  }

  /** One fresh scan, classified by the pure whitelist (never the cache). */
  private async classifyFresh(target: PortKillTarget) {
    const scan = await this.doScan();
    return classifyKillTarget(target, scan, this.killGuards(scan.procs));
  }

  /**
   * The same check, but retried while the scan itself is unavailable — used ONLY
   * after a signal has gone out.
   *
   * A process that has just been signalled is mid-exit, and a scan taken in that
   * window can genuinely fail: the pid is still in the listener table when the
   * pid list is built and gone (or a zombie) by the time `lsof -p` reads it, which
   * on Linux yields a non-zero exit with no output — an unusable scan. Reporting
   * that as `scan_unavailable` told the user "nothing was killed" about a kill
   * that had in fact worked (CI caught this; macOS hid it, because its `lsof`
   * prints partial output instead).
   *
   * The retry is bounded and short: the condition clears as soon as the process is
   * fully reaped. A PRE-signal scan is never retried — R1 must refuse immediately
   * rather than keep re-reading sockets before deciding to signal.
   */
  private async classifyFreshAfterSignal(target: PortKillTarget) {
    let decision = await this.classifyFresh(target);
    for (let attempt = 0; attempt < POST_SIGNAL_SCAN_RETRIES; attempt++) {
      if (decision.signal || decision.outcome !== "scan_unavailable") break;
      await this.sleep(POST_SIGNAL_RETRY_MS);
      decision = await this.classifyFresh(target);
    }
    return decision;
  }

  /** This process, its ancestors, and every live agent root (D3 R5–R7). */
  private killGuards(procs: Map<number, ProcInfo> | undefined): KillGuards {
    const serverAncestors = new Set<number>();
    if (procs !== undefined) {
      for (const pid of walkAncestors(this.serverPid, procs)) serverAncestors.add(pid);
    }
    return {
      serverPid: this.serverPid,
      serverAncestors,
      sessionRoots: new Set(this.deps.listSessionRoots().values()),
    };
  }

  /**
   * Deliver one signal, mapping `process.kill`'s two expected throws onto facts:
   * `ESRCH` (the pid is gone) and `EPERM` (not ours to signal). Any other error
   * is also reported as `denied` — an unexpected signal failure must never read
   * as a success.
   */
  private trySignal(pid: number, sig: NodeJS.Signals): "sent" | "gone" | "denied" {
    try {
      this.signal(pid, sig);
      return "sent";
    } catch (err) {
      const code = (err as { code?: string }).code;
      if (code === "ESRCH") return "gone";
      log.warn(`[ports] ${sig} to pid ${pid} failed: ${(err as Error).message}`);
      return "denied";
    }
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
      // The cadence path owns the outage side effects (see the note in
      // `doScan`): only a scheduled scan may retire the last-good list or tell
      // the down-detector what it saw.
      if (outcome.scanOk) {
        this.lastGoodPorts = outcome.ports;
        this.downDetector.observe(outcome.ports, this.deps.watchedPorts?.() ?? []);
      }
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

      // Docker last: it is the only annotation that costs an exec, and it can
      // only ever apply to a listener the previous passes left unowned.
      const withDocker = await this.overlayDocker(annotated);

      // SPEC-44: mark what the user asked to be told about. The annotation lives
      // here because BOTH the cadence path and the on-demand paths (kill,
      // forward) publish/judge these ports.
      const watched = this.deps.watchedPorts?.() ?? [];
      const withWatched =
        watched.length === 0
          ? withDocker
          : withDocker.map((port) =>
              isWatched(watched, port.worktreePath, port.port)
                ? { ...port, watched: true }
                : port,
            );

      // NOTE: the outage detector and `lastGoodPorts` are deliberately NOT
      // touched here. `doScan` is also called off-cadence by `killPort` (up to
      // three times per kill) and by `scanNow` (every forward request), none of
      // which hold the `scanning` guard — feeding the detector from those would
      // let a kill's own mid-flight scans look like an outage. Both side effects
      // live in `runScan`, the one path the cadence owns.
      return { ports: withWatched, scanOk: true, historyToSave, procs };
    } catch (err) {
      return {
        ports: this.lastGoodPorts,
        scanOk: false,
        scanError: `port scan failed: ${(err as Error).message}`,
      };
    }
  }

  /**
   * Name the container behind each port docker's proxy is holding (D13).
   *
   * Nothing runs unless this scan actually found a docker-held listener, so a
   * machine with no containers pays nothing at all. A failed read (`ok:false`)
   * leaves every port untouched: "we could not ask docker" must never render as
   * "not a container". `reach` is never rewritten — a published port bound to
   * `0.0.0.0` stays `exposed`.
   */
  private async overlayDocker(ports: PortDTO[]): Promise<PortDTO[]> {
    if (!ports.some((p) => isDockerBackend(p.command))) return ports;
    const read = await this.readDocker(EXEC_TIMEOUT_MS);
    if (!read.ok) return ports;
    return ports.map((port) => {
      if (!isDockerBackend(port.command)) return port;
      const docker = read.byHostPort.get(port.port);
      return docker === undefined ? port : { ...port, docker };
    });
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
