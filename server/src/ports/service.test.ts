import assert from "node:assert/strict";
import { test } from "node:test";

import { PortsService, SCAN_INTERVAL_MS } from "./service.js";
import type { Exec } from "./scan.js";
import type { PortsSnapshotDTO } from "../protocol.js";

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
  refreshCount: () => number;
  tick: () => void;
  cleared: () => number;
  setExec: (e: Exec) => void;
}

function harness(overrides: Partial<Parameters<typeof makeService>[0]> = {}): Harness {
  return makeService(overrides);
}

function makeService(overrides: {
  exec?: Exec;
  listWorktreePaths?: () => string[];
  now?: () => number;
} = {}) {
  const snapshots: PortsSnapshotDTO[] = [];
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
    listSessionRoots: () => new Map(),
    tailnetAddress: () => null,
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
    refreshCount: () => refreshes,
    tick: () => {
      for (const t of timers) if (!t.cancelled) t.fn();
    },
    cleared: () => clears,
    setExec: (e: Exec) => {
      exec = e;
    },
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
