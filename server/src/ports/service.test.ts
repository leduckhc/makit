import assert from "node:assert/strict";
import { test } from "node:test";

import { PortsService, SCAN_INTERVAL_MS } from "./service.js";
import type { Exec } from "./scan.js";
import type { PortsSnapshotDTO } from "../protocol.js";
import type { PortHistory } from "./history_store.js";

const LISTENER_OUT = ["p200", "u501", "f3", "PTCP", "n127.0.0.1:5173"].join("\n");
const PS_OUT = ["  200 100 01:00:00 node vite", "  100 1 01:00:01 pnpm dev"].join("\n");
const CWD_OUT = ["p200", "fcwd", "n/repo/wt-a", "p100", "fcwd", "n/repo/wt-a"].join("\n");

interface Harness {
  service: PortsService;
  snapshots: PortsSnapshotDTO[];
  /** Number of listener scans STARTED (lsof -iTCP invocations), not published. */
  scanCount: () => number;
  /** Total execs of ANY kind (lsof + ps + cwd lsof). */
  execCount: () => number;
  /** `docker ps` invocations — the P2c cost this feature promises to skip. */
  dockerCount: () => number;
  refreshCount: () => number;
  tick: () => void;
  cleared: () => number;
  setExec: (e: Exec) => void;
  /** Signals the service asked for, in order (SPEC-ports-kill — never a real kill). */
  signals: () => { pid: number; sig: string }[];
  /** Sleeps the service awaited, in ms (the SIGTERM grace window). */
  sleeps: () => number[];
}

function harness(overrides: Partial<Parameters<typeof makeService>[0]> = {}): Harness {
  return makeService(overrides);
}

function makeService(overrides: {
  exec?: Exec;
  listWorktreePaths?: () => string[];
  listWorktreeBranches?: () => Map<string, string>;
  loadHistory?: () => PortHistory;
  saveHistory?: (h: PortHistory) => void;
  listSessionRoots?: () => Map<string, number>;
  watchedPorts?: () => { worktreePath: string; port: number }[];
  onPortDown?: (port: { worktreePath: string; port: number }) => void;
  now?: () => number;
  serverPid?: number;
  signal?: (pid: number, sig: NodeJS.Signals) => void;
} = {}) {
  const snapshots: PortsSnapshotDTO[] = [];
  const signals: { pid: number; sig: string }[] = [];
  const sleeps: number[] = [];
  const execLog: { cmd: string; args: string[] }[] = [];
  let refreshes = 0;
  const timers: { fn: () => void; cancelled: boolean }[] = [];
  let clears = 0;

  const defaultExec: Exec = async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP")) {
      return { code: 0, stdout: LISTENER_OUT, stderr: "" };
    }
    if (cmd === "ps") return { code: 0, stdout: PS_OUT, stderr: "" };
    if (cmd === "lsof") return { code: 0, stdout: CWD_OUT, stderr: "" };
    return { code: 0, stdout: "", stderr: "" };
  };

  let exec = overrides.exec ?? defaultExec;
  const isListenerScan = (e: { cmd: string; args: string[] }) =>
    e.cmd === "lsof" && e.args.includes("-iTCP");

  const service = new PortsService({
    exec: (cmd, args, cwd, timeoutMs) => {
      execLog.push({ cmd, args });
      return exec(cmd, args, cwd, timeoutMs);
    },
    probe: {
      refresh: async () => {
        refreshes++;
      },
      verdict: () => undefined,
    },
    listWorktreePaths: overrides.listWorktreePaths ?? (() => ["/repo/wt-a"]),
    listWorktreeBranches: overrides.listWorktreeBranches ?? (() => new Map()),
    loadHistory: overrides.loadHistory ?? (() => ({ entries: [] })),
    saveHistory: overrides.saveHistory ?? (() => {}),
    listSessionRoots: overrides.listSessionRoots ?? (() => new Map()),
    watchedPorts: overrides.watchedPorts ?? (() => []),
    onPortDown: overrides.onPortDown ?? (() => {}),
    tailnetAddress: () => null,
    serverPid: overrides.serverPid ?? 999_999,
    signal: (pid, sig) => {
      signals.push({ pid, sig });
      overrides.signal?.(pid, sig);
    },
    sleep: async (ms) => {
      sleeps.push(ms);
    },
    onSnapshot: (s) => snapshots.push(s),
    now: overrides.now ?? (() => 1_700_000_000_000),
    setTimer: (fn) => {
      const h = { fn, cancelled: false };
      timers.push(h);
      return h;
    },
    clearTimer: (h) => {
      (h as { cancelled: boolean }).cancelled = true;
      clears++;
    },
    resolveReal: (p) => p,
  });

  return {
    service,
    snapshots,
    scanCount: () => execLog.filter(isListenerScan).length,
    execCount: () => execLog.length,
    dockerCount: () => execLog.filter((e) => e.cmd === "docker").length,
    refreshCount: () => refreshes,
    tick: () => {
      for (const t of timers) if (!t.cancelled) t.fn();
    },
    cleared: () => clears,
    setExec: (e: Exec) => {
      exec = e;
    },
    signals: () => signals,
    sleeps: () => sleeps,
  };
}

const flush = () => new Promise((r) => setImmediate(r));

test("zero watchers → ZERO execs of ANY kind (nothing is scanned until someone watches)", async () => {
  const h = harness();
  await flush();
  h.service.setWatchers(0);
  await flush();
  assert.equal(h.execCount(), 0, "not even a stray ps or cwd lsof");
});

test("0→1 runs exactly one immediate scan and publishes it", async () => {
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.scanCount(), 1);
  assert.equal(h.snapshots.length, 1);
  assert.equal(h.snapshots[0]!.ports[0]!.port, 5173);
  assert.equal(h.snapshots[0]!.ports[0]!.worktreePath, "/repo/wt-a");
  assert.equal(h.snapshots[0]!.scanOk, true);
});

test("SCAN_INTERVAL_MS is 4000 and a tick while watched runs another scan", async () => {
  assert.equal(SCAN_INTERVAL_MS, 4000);
  // A deterministic per-scan worktree path (the assertion is about scanCount, not
  // the path value) — a fresh path each scan just proves ticks re-scan.
  let scan = 0;
  const h = harness({ listWorktreePaths: () => [`/repo/wt-${scan++}`] });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.scanCount(), 1);
  h.tick();
  await flush();
  assert.equal(h.scanCount(), 2);
});

test("a tick that fires during an in-flight scan is SKIPPED (no overlap, no queue)", async () => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const h = harness();
  h.setExec(async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP")) {
      await gate; // hang the first scan
      return { code: 0, stdout: LISTENER_OUT, stderr: "" };
    }
    if (cmd === "ps") return { code: 0, stdout: PS_OUT, stderr: "" };
    return { code: 0, stdout: CWD_OUT, stderr: "" };
  });
  h.service.setWatchers(1); // starts scan 1 (blocked on the gate)
  await flush();
  h.tick(); // would-be scan 2, must be skipped while scan 1 is in flight
  h.tick();
  await flush();
  // Exactly one listener scan was STARTED, despite two extra ticks — asserting
  // the scan count, not the publish count: a second overlapping scan that merely
  // suppressed its own publish would slip past a publications-only assertion.
  assert.equal(h.scanCount(), 1, "only one listener scan started");
  release();
  await flush();
  assert.equal(h.snapshots.length, 1);
});

test("1→0 disarms the timer AND a later tick performs no execs", async () => {
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  const before = h.cleared();
  const execsAfterFirstScan = h.execCount();
  h.service.setWatchers(0);
  assert.equal(h.cleared(), before + 1, "the timer is disarmed");
  h.tick(); // a disarmed timer must fire nothing
  await flush();
  assert.equal(h.execCount(), execsAfterFirstScan, "no exec of any kind after disarm");
});

test("listener lsof succeeds but ps FAILS → scanOk:false, last good ports kept", async () => {
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  const good = h.snapshots[0]!.ports;
  assert.equal(good.length, 1);
  h.setExec(async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP"))
      return { code: 0, stdout: LISTENER_OUT, stderr: "" };
    if (cmd === "ps") return { code: 1, stdout: "", stderr: "ps: boom" }; // ps fails
    return { code: 0, stdout: CWD_OUT, stderr: "" };
  });
  h.tick();
  await flush();
  const last = h.snapshots[h.snapshots.length - 1]!;
  assert.equal(last.scanOk, false);
  assert.match(last.scanError ?? "", /ps/);
  assert.deepEqual(last.ports, good, "the last good ports are retained");
});

test("listener lsof succeeds but the cwd lsof FAILS → scanOk:false, last good ports kept", async () => {
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  const good = h.snapshots[0]!.ports;
  assert.equal(good.length, 1);
  h.setExec(async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP"))
      return { code: 0, stdout: LISTENER_OUT, stderr: "" };
    if (cmd === "ps") return { code: 0, stdout: PS_OUT, stderr: "" };
    return { code: 127, stdout: "", stderr: "lsof: command not found" }; // cwd lsof unavailable
  });
  h.tick();
  await flush();
  const last = h.snapshots[h.snapshots.length - 1]!;
  assert.equal(last.scanOk, false);
  assert.match(last.scanError ?? "", /cwd lsof/);
  assert.deepEqual(last.ports, good, "the last good ports are retained");
});

test("a scan finishing after the last watcher leaves publishes nothing", async () => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const h = harness();
  h.setExec(async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP")) {
      await gate;
      return { code: 0, stdout: LISTENER_OUT, stderr: "" };
    }
    if (cmd === "ps") return { code: 0, stdout: PS_OUT, stderr: "" };
    return { code: 0, stdout: CWD_OUT, stderr: "" };
  });
  h.service.setWatchers(1);
  await flush();
  h.service.setWatchers(0); // last watcher leaves mid-scan
  release();
  await flush();
  assert.equal(h.snapshots.length, 0, "an in-flight scan must not re-arm anything");
});

test("an identical snapshot does NOT re-broadcast (projection excludes scannedAt)", async () => {
  // now advances between scans, and so does the process's elapsed time — so
  // `startedAt` (now − elapsed) stays constant while `scannedAt` moves. Only the
  // excluded `scannedAt` differs, so the projection is identical.
  let clock = 1_000_000;
  const start = clock;
  const fmt = (sec: number) => {
    const s = String(sec % 60).padStart(2, "0");
    const m = String(Math.floor(sec / 60)).padStart(2, "0");
    return `00:${m}:${s}`;
  };
  const h = makeService({
    now: () => clock,
    exec: async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP"))
        return { code: 0, stdout: LISTENER_OUT, stderr: "" };
      if (cmd === "ps") {
        const elapsed = 600 + Math.floor((clock - start) / 1000);
        return { code: 0, stdout: `  200 100 ${fmt(elapsed)} node vite\n  100 1 ${fmt(elapsed)} pnpm dev`, stderr: "" };
      }
      return { code: 0, stdout: CWD_OUT, stderr: "" };
    },
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots.length, 1);
  clock = 1_004_000; // scannedAt advances 4 s; startedAt is unchanged
  h.tick();
  await flush();
  assert.equal(h.snapshots.length, 1, "identical projection is not rebroadcast");
  // The cache must NOT advance when the broadcast was skipped: a freshly-arrived
  // watcher is hydrated from `cachedSnapshot()`, and it must receive exactly what
  // the existing watchers last received — not a newer snapshot no one else got.
  assert.equal(
    h.service.cachedSnapshot()!.scannedAt,
    h.snapshots[0]!.scannedAt,
    "cache stays pinned to the last BROADCAST snapshot",
  );
});

test("a startedAt-only change does NOT re-broadcast (projection excludes startedAt)", async () => {
  // `ps` reports `etime` at ONE-second granularity while `now` is per-scan, so
  // `startedAt = now - elapsed` jitters by up to 1000 ms between ticks even when
  // nothing changed. That jitter must not force a re-broadcast — only a real
  // change (pid, port, address, …) should. `now` is held constant here so the
  // ONLY difference between the two scans is `startedAt` (finding 25).
  let etime = "01:00:00";
  const h = makeService({
    exec: async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP"))
        return { code: 0, stdout: LISTENER_OUT, stderr: "" };
      if (cmd === "ps")
        return { code: 0, stdout: `  200 100 ${etime} node vite\n  100 1 ${etime} pnpm dev`, stderr: "" };
      return { code: 0, stdout: CWD_OUT, stderr: "" };
    },
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots.length, 1);
  etime = "01:00:01"; // elapsed advanced 1 s → startedAt shifts by 1000 ms, nothing else
  h.tick();
  await flush();
  assert.equal(h.snapshots.length, 1, "a startedAt-only difference must not re-broadcast");
});

test("a throwing scan keeps the last good ports and sets scanOk:false", async () => {
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  const good = h.snapshots[0]!.ports;
  assert.equal(good.length, 1);
  // Now make worktree lookup throw on the next scan.
  h.setExec(async () => {
    throw new Error("boom");
  });
  h.tick();
  await flush();
  const last = h.snapshots[h.snapshots.length - 1]!;
  assert.equal(last.scanOk, false);
  assert.ok(typeof last.scanError === "string" && last.scanError.length > 0);
  assert.deepEqual(last.ports, good, "the last good ports are retained");
});

test("health refresh fires after a publish (results land next tick)", async () => {
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.refreshCount(), 1);
});

test("the cached snapshot is available for a freshly-arrived watcher", async () => {
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  const cached = h.service.cachedSnapshot();
  assert.ok(cached);
  assert.equal(cached!.ports[0]!.port, 5173);
});

// --- T11: port-history wiring (upsert → annotate → debounced save) ---

/** An in-memory fake of the injected history store: load returns what save last stored. */
function fakeHistory() {
  let stored: PortHistory = { entries: [] };
  const saves: PortHistory[] = [];
  return {
    loadHistory: () => stored,
    saveHistory: (h: PortHistory) => {
      stored = h;
      saves.push(h);
    },
    saves,
    current: () => stored,
  };
}

test("a scan with an owned port upserts it into the injected history store", async () => {
  const store = fakeHistory();
  const h = makeService({
    loadHistory: store.loadHistory,
    saveHistory: store.saveHistory,
    listWorktreeBranches: () => new Map([["/repo/wt-a", "feat/a"]]),
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(store.saves.length, 1, "the history sink received one write");
  const entry = store.current().entries.find((e) => e.worktreePath === "/repo/wt-a");
  assert.ok(entry, "the owned worktree was recorded");
  assert.deepEqual(entry!.ports, [5173]);
  assert.equal(entry!.branch, "feat/a");
});

test("a rescan after the worktree leaves activeWorktreePaths yields an orphan-annotated snapshot", async () => {
  const store = fakeHistory();
  let active = ["/repo/wt-a"];
  const h = makeService({
    loadHistory: store.loadHistory,
    saveHistory: store.saveHistory,
    listWorktreePaths: () => active,
    listWorktreeBranches: () => new Map([["/repo/wt-a", "feat/a"]]),
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots[0]!.ports[0]!.worktreePath, "/repo/wt-a");
  assert.equal(h.snapshots[0]!.ports[0]!.orphan, undefined);

  // The worktree is removed; its port keeps listening but is now unowned.
  active = [];
  h.tick();
  await flush();
  const last = h.snapshots[h.snapshots.length - 1]!;
  assert.equal(last.ports[0]!.worktreePath, undefined, "the port is now unowned");
  assert.equal(last.ports[0]!.orphan?.formerWorktreePath, "/repo/wt-a");
  assert.equal(last.ports[0]!.orphan?.formerBranch, "feat/a");
  assert.equal(typeof last.ports[0]!.orphan?.removedAt, "number");
});

test("the history write is debounced — an identical projection does not write again", async () => {
  const store = fakeHistory();
  const h = makeService({
    loadHistory: store.loadHistory,
    saveHistory: store.saveHistory,
    listWorktreeBranches: () => new Map([["/repo/wt-a", "feat/a"]]),
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(store.saves.length, 1);
  h.tick(); // identical scan → identical projection → no broadcast, no write
  await flush();
  assert.equal(store.saves.length, 1, "no second write for an unchanged projection");
});

test("a THROWING history read keeps the scan alive (scanOk reflects the scan, not the store)", async () => {
  const h = makeService({
    loadHistory: () => {
      throw new Error("history store on fire");
    },
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots.length, 1);
  assert.equal(h.snapshots[0]!.scanOk, true, "the scan succeeds despite the store throwing");
  assert.equal(h.snapshots[0]!.ports[0]!.port, 5173, "ports are still published, unannotated");
  assert.equal(h.snapshots[0]!.ports[0]!.orphan, undefined);
});

// ── SPEC-ports-global-view P2c: the docker overlay (D13) ────────────────────────────────────

/** A listener held by docker's host-side proxy on a published port. */
const DOCKER_LISTENER_OUT = ["p901", "u501", "f3", "PTCP", "n0.0.0.0:5432"].join("\n");
const DOCKER_PS_OUT = "  901 1 02:00:00 com.docker.backend";
const DOCKER_CWD_OUT = ["p901", "fcwd", "n/"].join("\n");
const DOCKER_PS_LINE = [
  "chat-ui-db-1",
  "0.0.0.0:5432->5432/tcp",
  "/repo/chat-ui/compose.yml",
].join("\t");

/** An exec whose only listener is docker's proxy; `docker ps` answers `result`. */
function dockerExec(result: { code: number; stdout: string; stderr: string }): Exec {
  return async (cmd, args) => {
    if (cmd === "docker") return result;
    if (cmd === "lsof" && args.includes("-iTCP")) {
      return { code: 0, stdout: DOCKER_LISTENER_OUT, stderr: "" };
    }
    if (cmd === "ps") return { code: 0, stdout: DOCKER_PS_OUT, stderr: "" };
    return { code: 0, stdout: DOCKER_CWD_OUT, stderr: "" };
  };
}

test("a docker-backend listener on a published port gains `docker`, and keeps its reach", async () => {
  const h = harness({ exec: dockerExec({ code: 0, stdout: DOCKER_PS_LINE, stderr: "" }) });
  h.service.setWatchers(1);
  await flush();
  const port = h.snapshots[0]!.ports[0]!;
  assert.equal(port.port, 5432);
  assert.equal(port.docker?.container, "chat-ui-db-1");
  assert.equal(port.docker?.compose, "/repo/chat-ui/compose.yml");
  assert.equal(port.reach, "exposed", "docker is ownership, not reach (D13)");
});

test("a machine with NO docker publishes a normal snapshot and stops probing", async () => {
  // The `run()` 127 trap plus the cost promise: an absent binary must not read
  // as "no containers", and must not be paid for on every later scan.
  const h = harness({
    exec: dockerExec({ code: 127, stdout: "", stderr: "spawn docker ENOENT" }),
  });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots[0]!.scanOk, true);
  assert.equal(h.snapshots[0]!.ports[0]!.port, 5432);
  assert.equal(h.snapshots[0]!.ports[0]!.docker, undefined, "absent, not fabricated");
  assert.equal(h.dockerCount(), 1);

  h.tick();
  await flush();
  assert.equal(h.dockerCount(), 1, "no docker binary — never spawned again");
});

test("no docker-proxy listener → `docker ps` is never spawned at all", async () => {
  // The default harness listener is `node vite`. Probing docker on a machine
  // whose scan contains no docker-held port would be a per-scan exec for an
  // annotation that could not apply to anything.
  const h = harness();
  h.service.setWatchers(1);
  await flush();
  h.tick();
  await flush();
  assert.equal(h.dockerCount(), 0);
});

// ── SPEC-ports-kill P3a: killPort — the orchestrator (D1/D2) ───────────────────────
//
// No real process is ever signalled: `signal` and `sleep` are injected, and the
// scripted `exec` decides what the "fresh" scans see. The classifier's own
// refusal table lives in `kill.test.ts`; these tests are about the SEQUENCE —
// SIGTERM, a re-verified grace window, then at most one SIGKILL.

const KILL_NOW = 1_700_000_000_000;
/** `PS_OUT`'s `01:00:00` etime against `KILL_NOW`, i.e. the target's startedAt. */
const KILL_STARTED_AT = KILL_NOW - 3_600_000;
const KILL_TARGET = { address: "127.0.0.1", port: 5173, pid: 200, startedAt: KILL_STARTED_AT };

/**
 * A scripted exec whose listener table changes per scan: `alive[i]` is what the
 * i-th scan sees (`true` = the target still listening, `false` = endpoint free,
 * `"recycled"` = the endpoint taken by a DIFFERENT pid). The last entry repeats.
 */
function killExec(alive: (boolean | "recycled")[]): { exec: Exec; scans: () => number } {
  let scan = -1;
  const exec: Exec = async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP")) {
      scan++;
      const state = alive[Math.min(scan, alive.length - 1)]!;
      if (state === false) return { code: 0, stdout: "", stderr: "" };
      const pid = state === "recycled" ? 4242 : 200;
      return {
        code: 0,
        stdout: [`p${pid}`, "u501", "f3", "PTCP", "n127.0.0.1:5173"].join("\n"),
        stderr: "",
      };
    }
    if (cmd === "ps") {
      return {
        code: 0,
        stdout: [
          "  200 100 01:00:00 node vite",
          "  100 1 01:00:01 pnpm dev",
          "  4242 100 00:00:02 node vite",
          // A makit server running as a CHILD of the listener, so a kill on 200
          // would take the server down with it (R6's ancestor case).
          "  777 200 00:00:05 node makit serve",
        ].join("\n"),
        stderr: "",
      };
    }
    if (cmd === "lsof") {
      return {
        code: 0,
        stdout: ["p200", "fcwd", "n/repo/wt-a", "p4242", "fcwd", "n/repo/wt-a"].join("\n"),
        stderr: "",
      };
    }
    return { code: 0, stdout: "", stderr: "" };
  };
  return { exec, scans: () => scan + 1 };
}

test("SIGTERM frees the endpoint → released, and NO SIGKILL is sent", async () => {
  const { exec } = killExec([true, false]);
  const h = harness({ exec, now: () => KILL_NOW });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "released");
  assert.deepEqual(result.address, "127.0.0.1");
  assert.deepEqual(
    h.signals(),
    [{ pid: 200, sig: "SIGTERM" }],
    "escalating to SIGKILL after a clean SIGTERM is the mutation this bites",
  );
  assert.deepEqual(h.sleeps(), [2_000]);
});

test("a process that IGNORES SIGTERM is SIGKILLed → force-killed", async () => {
  // Scans: 1 verify, 2 post-grace re-verify (still there), 3 post-SIGKILL.
  const { exec } = killExec([true, true, false]);
  const h = harness({ exec, now: () => KILL_NOW });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "force-killed");
  assert.deepEqual(h.signals(), [
    { pid: 200, sig: "SIGTERM" },
    { pid: 200, sig: "SIGKILL" },
  ]);
});

test("still listening after SIGKILL → survived (never a false success)", async () => {
  const { exec } = killExec([true]);
  const h = harness({ exec, now: () => KILL_NOW });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "survived");
});

test("R8: pid churn inside the grace window never redirects the SIGKILL", async () => {
  // The target exits during the window and the OS hands 5173 to pid 4242. The
  // pre-SIGKILL re-verify (D1 again) is the only thing standing between that
  // and SIGKILLing an innocent process.
  const { exec } = killExec([true, "recycled"]);
  const h = harness({ exec, now: () => KILL_NOW });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "released", "our target is gone — that is a release");
  assert.deepEqual(
    h.signals(),
    [{ pid: 200, sig: "SIGTERM" }],
    "a SIGKILL here would land on the recycled pid",
  );
});

test("ESRCH from the SIGTERM means it exited between scan and signal → released", async () => {
  const { exec } = killExec([true]);
  const h = harness({
    exec,
    now: () => KILL_NOW,
    signal: () => {
      const err = new Error("no such process") as Error & { code: string };
      err.code = "ESRCH";
      throw err;
    },
  });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "released");
  assert.deepEqual(h.sleeps(), [], "nothing to wait for — the process is already gone");
});

test("EPERM means someone else's process → survived, and no escalation", async () => {
  const { exec } = killExec([true]);
  const h = harness({
    exec,
    now: () => KILL_NOW,
    signal: () => {
      const err = new Error("operation not permitted") as Error & { code: string };
      err.code = "EPERM";
      throw err;
    },
  });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "survived");
  assert.deepEqual(h.sleeps(), []);
});

test("a failed kill-path scan refuses, and signals nothing (R1)", async () => {
  const h = harness({
    exec: async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP")) {
        return { code: 127, stdout: "", stderr: "lsof: not found" };
      }
      return { code: 0, stdout: "", stderr: "" };
    },
    now: () => KILL_NOW,
  });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "scan_unavailable");
  assert.deepEqual(h.signals(), []);
});

test("the kill path ignores the cached snapshot — it always rescans", async () => {
  // A watcher is holding the scan, so a cache exists; the kill must not read it.
  const { exec, scans } = killExec([true, false]);
  const h = harness({ exec, now: () => KILL_NOW });
  h.service.setWatchers(1);
  await flush();
  const before = scans();
  await h.service.killPort(KILL_TARGET);
  assert.ok(scans() > before, "killPort ran its own fresh scan");
});

test("makit's own server pid is refused (R6)", async () => {
  const { exec } = killExec([true]);
  const h = harness({ exec, now: () => KILL_NOW, serverPid: 200 });
  assert.equal((await h.service.killPort(KILL_TARGET)).outcome, "refused_self");
  assert.deepEqual(h.signals(), []);
});

test("an ANCESTOR of the server pid is refused — killing it kills us (R6)", async () => {
  // pid 777 (the server) is a child of 200 (the listener), so 200 is an ancestor
  // of this process. Dropping the ancestor walk is the mutation this bites.
  const { exec } = killExec([true]);
  const h = harness({ exec, now: () => KILL_NOW, serverPid: 777 });
  assert.equal((await h.service.killPort(KILL_TARGET)).outcome, "refused_self");
  assert.deepEqual(h.signals(), []);
});

test("an unrelated server pid does not block the kill", async () => {
  const { exec } = killExec([true, false]);
  const h = harness({ exec, now: () => KILL_NOW, serverPid: 12_345 });
  assert.equal((await h.service.killPort(KILL_TARGET)).outcome, "released");
});

test("a session's agent root is refused — session.kill owns it (R7)", async () => {
  const { exec } = killExec([true]);
  const h = harness({
    exec,
    now: () => KILL_NOW,
    listSessionRoots: () => new Map([["s1", 200]]),
  });
  assert.equal((await h.service.killPort(KILL_TARGET)).outcome, "refused_session");
  assert.deepEqual(h.signals(), []);
});

test("D7: every attempt writes ONE audit line — info on a kill, warn on a refusal", async () => {
  // The audit trail for a destructive remote action. Captured off `console.error`
  // because that is where `log.ts` writes (stderr, never a session's event log).
  const lines: string[] = [];
  const realError = console.error;
  console.error = (...args: unknown[]) => void lines.push(args.join(" "));
  try {
    const released = harness({ exec: killExec([true, false]).exec, now: () => KILL_NOW });
    await released.service.killPort(KILL_TARGET, { deviceId: "dev-7" });
    assert.equal(lines.length, 1);
    assert.match(lines[0]!, /kill 127\.0\.0\.1:5173 pid=200/);
    assert.match(lines[0]!, /device=dev-7/);
    assert.match(lines[0]!, /signals=SIGTERM → released/);

    lines.length = 0;
    const refused = harness({ exec: killExec([false]).exec, now: () => KILL_NOW });
    await refused.service.killPort(KILL_TARGET);
    assert.equal(lines.length, 1);
    assert.match(lines[0]!, /signals=none → not_found/);
    assert.match(lines[0]!, /device=-/, "an unidentified caller is named as unknown, not omitted");
  } finally {
    console.error = realError;
  }
});

// ── SPEC-ports-kill P3b: killOrphans (D5) ──────────────────────────────────────────

/**
 * A scan with two orphan listeners (5180, 5181) plus one owned port. `killed`
 * records which pids have been SIGTERMed so the follow-up scans see them gone.
 */
function orphanExec(killed: Set<number>, opts: { unkillable?: number } = {}): Exec {
  return async (cmd, args) => {
    if (cmd === "lsof" && args.includes("-iTCP")) {
      const rows: string[] = [];
      for (const [pid, port] of [
        [300, 5180],
        [301, 5181],
        [200, 5173],
      ] as const) {
        if (killed.has(pid) && pid !== opts.unkillable) continue;
        rows.push(`p${pid}`, "u501", "PTCP", `n127.0.0.1:${port}`);
      }
      return { code: 0, stdout: rows.join("\n"), stderr: "" };
    }
    if (cmd === "ps") {
      return {
        code: 0,
        stdout: [
          "  300 1 02:00:00 node vite --port 5180",
          "  301 1 02:00:00 node vite --port 5181",
          "  200 1 01:00:00 node vite",
        ].join("\n"),
        stderr: "",
      };
    }
    if (cmd === "lsof") {
      return {
        code: 0,
        stdout: [
          "p300",
          "fcwd",
          "n/repo/wt-gone",
          "p301",
          "fcwd",
          "n/repo/wt-gone",
          "p200",
          "fcwd",
          "n/repo/wt-a",
        ].join("\n"),
        stderr: "",
      };
    }
    return { code: 0, stdout: "", stderr: "" };
  };
}

/** History that remembers a worktree which is no longer active → two orphans. */
const ORPHAN_HISTORY: PortHistory = {
  entries: [
    {
      worktreePath: "/repo/wt-gone",
      branch: "gone/branch",
      ports: [5180, 5181],
      firstSeen: 1_699_000_000_000,
      lastSeen: 1_699_000_000_000,
    },
  ],
};

function orphanHarness(killed: Set<number>) {
  return harness({
    exec: orphanExec(killed),
    now: () => KILL_NOW,
    listWorktreePaths: () => ["/repo/wt-a"],
    loadHistory: () => ORPHAN_HISTORY,
    signal: (pid, sig) => {
      if (sig === "SIGTERM") killed.add(pid);
    },
  });
}

test("killOrphans kills every orphan and leaves owned ports alone (D5)", async () => {
  const killed = new Set<number>();
  const h = orphanHarness(killed);
  const { results } = await h.service.killOrphans();

  assert.deepEqual(
    results.map((r: { port: number; outcome: string }) => [r.port, r.outcome]),
    [
      [5180, "released"],
      [5181, "released"],
    ],
  );
  assert.deepEqual(
    h.signals().map((s) => s.pid).sort(),
    [300, 301],
    "the worktree-owned :5173 must never be swept up in a bulk orphan kill",
  );
});

test("killOrphans returns per-endpoint results — one failure never aborts the batch", async () => {
  // 300 ignores every signal (it stays in the scan), 301 dies. The honest
  // contract is a result per endpoint: you cannot roll back a signal, so an
  // "atomic bulk kill" would be a lie (D5).
  const killed = new Set<number>();
  const h = harness({
    exec: orphanExec(killed, { unkillable: 300 }),
    now: () => KILL_NOW,
    listWorktreePaths: () => ["/repo/wt-a"],
    loadHistory: () => ORPHAN_HISTORY,
    signal: (pid, sig) => {
      if (sig === "SIGTERM") killed.add(pid);
    },
  });
  const { results } = await h.service.killOrphans();
  assert.deepEqual(
    results.map((r: { port: number; outcome: string }) => [r.port, r.outcome]),
    [
      [5180, "survived"],
      [5181, "released"],
    ],
  );
});

test("killOrphans with no orphans signals nothing and returns an empty list", async () => {
  const h = harness({ exec: killExec([true]).exec, now: () => KILL_NOW });
  assert.deepEqual(await h.service.killOrphans(), { results: [] });
  assert.deepEqual(h.signals(), []);
});

test("killOrphans refuses everything when the fresh scan failed", async () => {
  const h = harness({
    exec: async (cmd, args) =>
      cmd === "lsof" && args.includes("-iTCP")
        ? { code: 127, stdout: "", stderr: "lsof: not found" }
        : { code: 0, stdout: "", stderr: "" },
    now: () => KILL_NOW,
  });
  // No scan ⇒ no orphan set ⇒ nothing to kill. Never a guess from the cache.
  assert.deepEqual(await h.service.killOrphans(), { results: [] });
  assert.deepEqual(h.signals(), []);
});

// ── SPEC-ports-forward P4a: watched ports (D7/D8) ─────────────────────────────────────

test("a watched, listening port is marked watched:true; others are absent", async () => {
  const h = harness({
    now: () => KILL_NOW,
    watchedPorts: () => [{ worktreePath: "/repo/wt-a", port: 5173 }],
  });
  h.service.setWatchers(1);
  await flush();
  const port = h.snapshots[0]!.ports[0]!;
  assert.equal(port.port, 5173);
  assert.equal(port.watched, true);

  // Absent, not `false`: absence means "not watched", the same rule every other
  // optional field on this DTO follows.
  const h2 = harness({ now: () => KILL_NOW });
  h2.service.setWatchers(1);
  await flush();
  assert.equal(h2.snapshots[0]!.ports[0]!.watched, undefined);
});

test("removing the watch clears the flag on the next snapshot", async () => {
  let watched = [{ worktreePath: "/repo/wt-a", port: 5173 }];
  const h = harness({ now: () => KILL_NOW, watchedPorts: () => watched });
  h.service.setWatchers(1);
  await flush();
  assert.equal(h.snapshots[0]!.ports[0]!.watched, true);

  watched = [];
  h.tick();
  await flush();
  assert.equal(h.snapshots.at(-1)!.ports[0]!.watched, undefined);
});

test("the down-detector is fed every scan, and fires after the grace window", async () => {
  const down: { worktreePath: string; port: number }[] = [];
  let alive = true;
  let now = KILL_NOW;
  const h = harness({
    now: () => now,
    watchedPorts: () => [{ worktreePath: "/repo/wt-a", port: 5173 }],
    onPortDown: (w) => down.push(w),
    exec: async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP")) {
        return {
          code: 0,
          stdout: alive ? ["p200", "u501", "PTCP", "n127.0.0.1:5173"].join("\n") : "",
          stderr: "",
        };
      }
      if (cmd === "ps") return { code: 0, stdout: "  200 100 01:00:00 node vite", stderr: "" };
      return { code: 0, stdout: ["p200", "fcwd", "n/repo/wt-a"].join("\n"), stderr: "" };
    },
  });
  h.service.setWatchers(1);
  await flush();
  assert.deepEqual(down, []);

  alive = false;
  h.tick();
  await flush();
  assert.deepEqual(down, [], "one absent tick is a restart, not an outage");

  now += 25_000;
  h.tick();
  await flush();
  assert.deepEqual(down, [{ worktreePath: "/repo/wt-a", port: 5173 }]);
});

test("with an EMPTY watch list the detector does no work at all", async () => {
  const down: unknown[] = [];
  const h = harness({ now: () => KILL_NOW, onPortDown: () => down.push(1) });
  h.service.setWatchers(1);
  await flush();
  h.tick();
  await flush();
  assert.deepEqual(down, []);
});

test("an off-cadence scan (a kill) never feeds the down-detector", async () => {
  // `killPort` runs up to three fresh scans of its own. If those fed the outage
  // detector, killing a watched port would look like an outage from inside the
  // kill — and `lastGoodPorts` would be retired by a scan the cadence never saw.
  const down: { worktreePath: string; port: number }[] = [];
  const h = harness({
    exec: killExec([true, false]).exec,
    now: () => KILL_NOW,
    watchedPorts: () => [{ worktreePath: "/repo/wt-a", port: 5173 }],
    onPortDown: (w) => down.push(w),
  });
  await h.service.killPort(KILL_TARGET);
  assert.deepEqual(down, [], "a kill's own scans are not observations");

  // Same for the forward path's `scanNow`. (A fresh recorder: `assert.deepEqual`
  // carries an `asserts` signature, so it narrows the first list to `never[]`.)
  const downFromScanNow: { worktreePath: string; port: number }[] = [];
  const h2 = harness({
    exec: killExec([false]).exec,
    now: () => KILL_NOW,
    watchedPorts: () => [{ worktreePath: "/repo/wt-a", port: 5173 }],
    onPortDown: (w) => downFromScanNow.push(w),
  });
  await h2.service.scanNow();
  assert.deepEqual(downFromScanNow, []);
});

test("scanNow returns a fresh scan without needing a watcher", async () => {
  // A capability decision (a forward) must not depend on somebody having a ports
  // list open — the published cache only advances when the service broadcasts.
  const h = harness({ now: () => KILL_NOW });
  assert.equal(h.service.cachedSnapshot(), undefined, "nothing published yet");
  const snapshot = await h.service.scanNow();
  assert.equal(snapshot.scanOk, true);
  assert.equal(snapshot.ports[0]?.port, 5173);
});

test("a post-signal scan that is momentarily unusable is RETRIED, not reported as a failure", async () => {
  // The window this covers: SIGTERM lands, the process is mid-exit, and the
  // verification scan taken in that instant fails (on Linux `lsof -p` for a pid
  // that vanished between the listing and the read exits non-zero with no
  // output). Reporting `scan_unavailable` there tells the user "nothing was
  // killed" about a kill that worked — which is how CI caught it.
  let scan = 0;
  const h = harness({
    now: () => KILL_NOW,
    exec: async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP")) {
        scan++;
        // 1: the pre-signal verify. 2: unusable (the dying-process window).
        // 3+: the process is reaped and the endpoint is free.
        if (scan === 1) {
          return {
            code: 0,
            stdout: ["p200", "u501", "PTCP", "n127.0.0.1:5173"].join("\n"),
            stderr: "",
          };
        }
        if (scan === 2) return { code: 127, stdout: "", stderr: "lsof: no such process" };
        return { code: 0, stdout: "", stderr: "" };
      }
      if (cmd === "ps") return { code: 0, stdout: "  200 100 01:00:00 node vite", stderr: "" };
      return { code: 0, stdout: ["p200", "fcwd", "n/repo/wt-a"].join("\n"), stderr: "" };
    },
  });

  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "released", "the retry saw the endpoint was freed");
  assert.deepEqual(h.signals(), [{ pid: 200, sig: "SIGTERM" }], "no spurious SIGKILL");
});

test("a PRE-signal unusable scan still refuses immediately (R1 is not retried)", async () => {
  // The retry is only for verifying a signal that already went out. Before one,
  // an unreadable scan must refuse at once rather than keep re-reading sockets
  // while deciding whether to signal.
  let scans = 0;
  const h = harness({
    now: () => KILL_NOW,
    exec: async (cmd, args) => {
      if (cmd === "lsof" && args.includes("-iTCP")) {
        scans++;
        return { code: 127, stdout: "", stderr: "lsof: not found" };
      }
      return { code: 0, stdout: "", stderr: "" };
    },
  });
  const result = await h.service.killPort(KILL_TARGET);
  assert.equal(result.outcome, "scan_unavailable");
  assert.equal(scans, 1, "one look, then refuse");
  assert.deepEqual(h.signals(), []);
});
