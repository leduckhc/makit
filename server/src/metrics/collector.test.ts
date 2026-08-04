import { test } from "node:test";
import assert from "node:assert/strict";

import {
  MetricsCollector,
  type AgentEntry,
  type CpuUsageSnapshot,
  type MetricsCollectorDeps,
  type MetricsSampleDTO,
} from "./collector.js";
import { CpuLedger } from "./ledger.js";
import type { SelfSample } from "./self.js";

/**
 * A manual timer scheduler: the collector arms exactly one timer at a time, so
 * we track the live handle, expose its interval, and `fire()` runs its callback
 * (which returns a promise we can await for deterministic async ticks).
 */
class FakeScheduler {
  private nextId = 1;
  private readonly fns = new Map<number, { fn: () => void; ms: number }>();
  /** Every arm, in order — lets a test prove a re-arm did (or did not) happen. */
  readonly arms: Array<{ id: number; ms: number }> = [];

  readonly setTimer = (fn: () => void, ms: number): unknown => {
    const id = this.nextId++;
    this.fns.set(id, { fn, ms });
    this.arms.push({ id, ms });
    return id;
  };

  readonly clearTimer = (handle: unknown): void => {
    this.fns.delete(handle as number);
  };

  get activeId(): number | undefined {
    const ids = [...this.fns.keys()];
    return ids.at(-1);
  }

  get activeMs(): number | undefined {
    const id = this.activeId;
    return id === undefined ? undefined : this.fns.get(id)!.ms;
  }

  async fire(): Promise<void> {
    const id = this.activeId;
    assert.ok(id !== undefined, "no active timer to fire");
    await (this.fns.get(id)!.fn() as unknown as Promise<void> | void);
  }
}

const SELF: SelfSample = {
  rssBytes: 111,
  cpuPercent: 0.5,
  loopDelayP50Ms: 1,
  loopDelayP99Ms: 2,
};

interface Harness {
  collector: MetricsCollector;
  scheduler: FakeScheduler;
  samples: MetricsSampleDTO[];
  metas: Array<{ coarse: boolean }>;
  execTimeouts: Array<number | undefined>;
  setStdout: (s: string) => void;
  setAgents: (a: AgentEntry[]) => void;
  setNow: (n: number) => void;
  setCpu: (c: CpuUsageSnapshot) => void;
}

function harness(overrides: Partial<MetricsCollectorDeps> = {}): Harness {
  const scheduler = new FakeScheduler();
  const samples: MetricsSampleDTO[] = [];
  const metas: Array<{ coarse: boolean }> = [];
  const execTimeouts: Array<number | undefined> = [];

  let stdout = "";
  let agents: AgentEntry[] = [];
  let clock = 1000;
  let cpu: CpuUsageSnapshot = { user: 0, system: 0 };

  const deps: MetricsCollectorDeps = {
    exec: async (_cmd, _args, _cwd, timeoutMs) => {
      execTimeouts.push(timeoutMs);
      return { code: 0, stdout, stderr: "" };
    },
    now: () => clock,
    setTimer: scheduler.setTimer,
    clearTimer: scheduler.clearTimer,
    self: { sample: () => SELF },
    wire: {
      sampleRates: () => ({ inBytesPerSec: 0, outBytesPerSec: 0, framesPerSec: 0 }),
    },
    ledger: new CpuLedger(),
    agents: () => agents,
    storage: async () => ({ eventLogBytes: 42 }),
    appPid: () => undefined,
    cpuUsage: () => cpu,
    onSample: (sample, meta) => {
      samples.push(sample);
      metas.push(meta);
    },
    watchedIntervalMs: 1_000,
    idleIntervalMs: 5_000,
    ringCapacity: 1_800,
    ...overrides,
  };

  return {
    collector: new MetricsCollector(deps),
    scheduler,
    samples,
    metas,
    execTimeouts,
    setStdout: (s) => {
      stdout = s;
    },
    setAgents: (a) => {
      agents = a;
    },
    setNow: (n) => {
      clock = n;
    },
    setCpu: (c) => {
      cpu = c;
    },
  };
}

/** `ps` stdout for one row. rss is KiB; time is `mm:ss.cc`. */
function row(pid: number, ppid: number, rssKib: number, cpuSec: number, comm: string): string {
  const mm = Math.floor(cpuSec / 60);
  const ss = (cpuSec % 60).toFixed(2).padStart(5, "0");
  return `${pid} ${ppid} ${rssKib} ${mm}:${ss} ${comm}`;
}

// ---------------------------------------------------------------------------
// Cadence.
// ---------------------------------------------------------------------------

test("start arms the idle cadence when no one is watching", () => {
  const h = harness();
  h.collector.start();
  assert.equal(h.scheduler.activeMs, 5_000);
});

test("first watcher switches 5s -> 1s and last unwatch switches back", () => {
  const h = harness();
  h.collector.start();
  assert.equal(h.scheduler.activeMs, 5_000);

  h.collector.setWatchers(1);
  assert.equal(h.scheduler.activeMs, 1_000);

  h.collector.setWatchers(0);
  assert.equal(h.scheduler.activeMs, 5_000);
});

test("setWatchers does NOT re-arm the timer when the interval is unchanged", () => {
  const h = harness();
  h.collector.start();
  h.collector.setWatchers(2); // 5s -> 1s: one re-arm
  const armsAfterSwitch = h.scheduler.arms.length;
  const handleAfterSwitch = h.scheduler.activeId;

  h.collector.setWatchers(3); // still watched: interval unchanged
  h.collector.setWatchers(5); // still watched: interval unchanged

  assert.equal(
    h.scheduler.arms.length,
    armsAfterSwitch,
    "interval unchanged must not re-arm (would reset the timer phase)",
  );
  assert.equal(h.scheduler.activeId, handleAfterSwitch, "timer handle must be stable");
});

test("stop clears the timer", () => {
  const h = harness();
  h.collector.start();
  h.collector.stop();
  assert.equal(h.scheduler.activeId, undefined);
});

// ---------------------------------------------------------------------------
// CPU rate (decision 2 — the null rule).
// ---------------------------------------------------------------------------

test("agent cpuPercent is null on the first tick and computed on the second", async () => {
  const h = harness();
  h.setAgents([{ sessionId: "s1", label: "pi", pid: 100, inTurn: false }]);
  h.collector.setWatchers(1);
  h.collector.start();

  h.setNow(1_000);
  h.setStdout(row(100, 1, 1024, 10, "node"));
  await h.scheduler.fire();
  assert.equal(h.samples[0].agents[0].cpuPercent, null);

  h.setNow(2_000);
  h.setStdout(row(100, 1, 1024, 12, "node"));
  await h.scheduler.fire();
  // (12 - 10) cpu-s over (2000-1000)ms = 1s => 200%.
  assert.equal(h.samples[1].agents[0].cpuPercent, 200);
});

test("a new agent appearing mid-stream gets null cpuPercent exactly once", async () => {
  const h = harness();
  h.collector.setWatchers(1);
  h.collector.start();

  h.setNow(1_000);
  h.setAgents([{ sessionId: "s1", label: "pi", pid: 100, inTurn: false }]);
  h.setStdout(row(100, 1, 1024, 10, "node"));
  await h.scheduler.fire();

  // Agent 200 joins on the second tick — it has no baseline yet.
  h.setNow(2_000);
  h.setAgents([
    { sessionId: "s1", label: "pi", pid: 100, inTurn: false },
    { sessionId: "s2", label: "codex", pid: 200, inTurn: false },
  ]);
  h.setStdout(`${row(100, 1, 1024, 12, "node")}\n${row(200, 1, 2048, 4, "codex")}`);
  await h.scheduler.fire();

  const s2First = h.samples[1].agents.find((a) => a.sessionId === "s2")!;
  const s1Second = h.samples[1].agents.find((a) => a.sessionId === "s1")!;
  assert.equal(s2First.cpuPercent, null, "new pid has no baseline yet");
  assert.equal(s1Second.cpuPercent, 200, "existing pid still computes its rate");

  // Third tick: agent 200 now has a baseline and computes a rate.
  h.setNow(3_000);
  h.setStdout(`${row(100, 1, 1024, 12, "node")}\n${row(200, 1, 2048, 5, "codex")}`);
  await h.scheduler.fire();
  const s2Second = h.samples[2].agents.find((a) => a.sessionId === "s2")!;
  assert.equal(s2Second.cpuPercent, 100, "(5-4)cpu-s / 1s => 100%");
});

// ---------------------------------------------------------------------------
// Assembly rules.
// ---------------------------------------------------------------------------

test("agents with pid undefined are omitted, not zeroed", async () => {
  const h = harness();
  h.collector.setWatchers(1);
  h.collector.start();
  h.setAgents([
    { sessionId: "s1", label: "pi", pid: 100, inTurn: false },
    { sessionId: "stub", label: "stub", pid: undefined, inTurn: false },
  ]);
  h.setStdout(row(100, 1, 1024, 3, "node"));
  await h.scheduler.fire();

  assert.equal(h.samples[0].agents.length, 1);
  assert.equal(h.samples[0].agents[0].sessionId, "s1");
});

test("turnActive is derived from the agents closure (incl. pid-less sessions)", async () => {
  const h = harness();
  h.collector.setWatchers(1);
  h.collector.start();
  h.setAgents([{ sessionId: "stub", label: "stub", pid: undefined, inTurn: true }]);
  await h.scheduler.fire();
  assert.equal(h.samples[0].turnActive, true);
});

test("storage is refreshed only every 6th tick; other ticks carry null", async () => {
  const h = harness();
  h.collector.setWatchers(1);
  h.collector.start();
  for (let i = 0; i < 7; i++) {
    h.setNow(1_000 + i * 1_000);
    await h.scheduler.fire();
  }
  assert.deepEqual(
    h.samples.map((s) => s.storage),
    [{ eventLogBytes: 42 }, null, null, null, null, null, { eventLogBytes: 42 }],
  );
});

test("coarse ticks omit per-agent procs/uptimeMs; fine ticks include them", async () => {
  const h = harness();
  h.setAgents([{ sessionId: "s1", label: "pi", pid: 100, inTurn: false }]);
  h.setStdout(row(100, 1, 1024, 3, "node"));

  // No watchers => coarse.
  h.collector.start();
  await h.scheduler.fire();
  assert.equal(h.metas[0].coarse, true);
  assert.equal(h.samples[0].agents[0].procs, undefined);
  assert.equal(h.samples[0].agents[0].uptimeMs, undefined);

  // A watcher => fine.
  h.collector.setWatchers(1);
  h.setNow(2_000);
  await h.scheduler.fire();
  assert.equal(h.metas[1].coarse, false);
  assert.equal(h.samples[1].agents[0].procs, 1);
  assert.equal(typeof h.samples[1].agents[0].uptimeMs, "number");
});

test("exec is called with the ps timeout bound", async () => {
  const h = harness();
  h.collector.setWatchers(1);
  h.collector.start();
  await h.scheduler.fire();
  assert.equal(h.execTimeouts[0], 800);
});

// ---------------------------------------------------------------------------
// Robustness: a throwing tick must not kill the collector.
// ---------------------------------------------------------------------------

test("a rejecting exec keeps the timer alive and flags the sample, then recovers", async () => {
  const originalError = console.error;
  let errorCount = 0;
  console.error = () => {
    errorCount++;
  };
  void errorCount;
  try {
    let fail = true;
    const h = harness({
      exec: async () => {
        if (fail) throw new Error("ps: command not found");
        return { code: 0, stdout: "", stderr: "" };
      },
    });
    h.collector.setWatchers(1);
    h.collector.start();
    const handle = h.scheduler.activeId;

    await h.scheduler.fire();
    await h.scheduler.fire();
    // `readProcTable` owns the failure: it returns {ok:false, empty table} rather
    // than rejecting, so ticks keep producing samples. That is deliberate — the
    // server row comes from process.memoryUsage(), not `ps`, so it is still valid
    // and worth showing while `ps` is broken.
    assert.equal(h.samples.length, 2, "ticks continue; the ps failure is reported in-band");
    assert.equal(
      h.samples[0].procTableOk,
      false,
      "a ps failure must be flagged, not shown as an empty machine",
    );
    assert.equal(h.scheduler.activeId, handle, "timer stays alive after a failed ps");

    // Recovery: once `ps` works again, samples are flagged ok.
    fail = false;
    await h.scheduler.fire();
    assert.equal(h.samples.length, 3);
    assert.equal(h.samples.at(-1)!.procTableOk, true, "recovers without a restart");
  } finally {
    console.error = originalError;
  }
});

// ---------------------------------------------------------------------------
// History + sampler self-cost.
// ---------------------------------------------------------------------------

test("historyFor returns the samples pushed within the 30-minute window", async () => {
  const h = harness();
  h.collector.setWatchers(1);
  h.collector.start();
  h.setNow(1_000);
  await h.scheduler.fire();
  h.setNow(2_000);
  await h.scheduler.fire();

  const history = h.collector.historyFor(2_000);
  assert.equal(history.length, 2);
  assert.deepEqual(history.map((s) => s.ts), [1_000, 2_000]);
});

test("sampler reports its own cpu cost measured around the tick", async () => {
  // now() is read at the start and end of the tick; advance it across the work.
  const times = [100, 150];
  const cpus: CpuUsageSnapshot[] = [
    { user: 0, system: 0 },
    { user: 5_000, system: 0 },
  ];
  const h = harness({
    now: () => times.shift()!,
    cpuUsage: () => cpus.shift()!,
  });
  h.collector.setWatchers(1);
  h.collector.start();
  await h.scheduler.fire();
  // 5000us over 50ms => 5000 / 50000 * 100 = 10%.
  assert.equal(h.samples[0].sampler.cpuPercent, 10);
});

// ---------------------------------------------------------------------------
// Clamp: a falling cumulative CPU total must never produce a negative rate.
// ---------------------------------------------------------------------------

test("a decreasing agent cpu total yields 0%, never a negative CPU%", async () => {
  // The ledger is not strictly monotonic (pid-reuse drops a frozen credit).
  const observations = [10, 8]; // second tick's total is LOWER than the first.
  const h = harness({
    ledger: { observe: () => observations.shift()! },
  });
  h.setAgents([{ sessionId: "s1", label: "pi", pid: 100, inTurn: false }]);
  h.setStdout(row(100, 1, 1024, 3, "node"));
  h.collector.setWatchers(1);
  h.collector.start();

  h.setNow(1_000);
  await h.scheduler.fire();
  assert.equal(h.samples[0].agents[0].cpuPercent, null);

  h.setNow(2_000);
  await h.scheduler.fire();
  assert.equal(
    h.samples[1].agents[0].cpuPercent,
    0,
    "a falling total is clamped to 0%, not (8-10)/1s => -200%",
  );
});

test("a negative server cpuPercent from self.ts is clamped to 0", async () => {
  const h = harness({
    self: { sample: () => ({ ...SELF, cpuPercent: -5 }) },
  });
  h.collector.setWatchers(1);
  h.collector.start();
  await h.scheduler.fire();
  assert.equal(h.samples[0].server.cpuPercent, 0);
});

test("a failed ps must not make live agents look like they exited (SPEC-32 lesson)", async () => {
  // Two agents are registered and running. `ps` then fails. The sample must NOT
  // read as "no agents": that is indistinguishable from every agent having quit,
  // which is exactly how SPEC-32's PR pills used to vanish under rate limits.
  const h = harness({
    exec: async () => {
      throw new Error("ps: command not found");
    },
    agents: () => [
      { sessionId: "s1", label: "pi", pid: 4242, inTurn: true },
      { sessionId: "s2", label: "codex", pid: 4243, inTurn: false },
    ],
  });
  h.collector.setWatchers(1);
  h.collector.start();
  await h.scheduler.fire();

  const s = h.samples.at(-1)!;
  assert.equal(s.procTableOk, false, "the reason the rows are missing must be legible");
  assert.deepEqual(s.agents, [], "no fabricated rows either — we genuinely did not measure");
  assert.equal(s.turnActive, true, "turn state comes from the session registry, not from ps");
  assert.ok(s.server.rssBytes >= 0, "the server row is still valid: it never came from ps");
});

// ── review findings (pass 1 on the server phase) ──────────────────────────────

test("per-pid rate state is pruned to live pids (no slow leak across session churn)", async () => {
  const h = harness();
  h.collector.setWatchers(1);
  h.collector.start();

  // 50 sessions come and go, one per tick, each with a distinct root pid.
  for (let i = 0; i < 50; i++) {
    const pid = 5000 + i;
    h.setAgents([{ sessionId: `s${i}`, label: "pi", pid, inTurn: false }]);
    h.setStdout(`  ${pid}     1   10240      0:01 pi`);
    await h.scheduler.fire();
  }

  // Only the currently-live pid keeps rate state, not all 50 ever seen.
  assert.equal(
    h.collector.trackedPidCount,
    1,
    "cpuBaseline/firstSeenMs must not grow one entry per pid ever seen",
  );
});

test("overlapping ticks are refused (a slow tick must not race its successor)", async () => {
  // A mutable holder, not a plain `let`: TS narrows an assigned-in-callback
  // variable to `never` at the call site.
  const gate: { open: () => void } = { open: () => {} };
  let execCalls = 0;
  const h = harness({
    exec: async () => {
      execCalls++;
      // First tick hangs until we release it; a second fire must be a no-op.
      if (execCalls === 1) {
        await new Promise<void>((resolve) => {
          gate.open = resolve;
        });
      }
      return { code: 0, stdout: "", stderr: "" };
    },
  });
  h.collector.setWatchers(1);
  h.collector.start();

  const firstTick = h.scheduler.fire(); // hangs inside exec
  await Promise.resolve();
  await h.scheduler.fire(); // must be skipped, not interleaved
  assert.equal(execCalls, 1, "a second tick must not start while the first is in flight");

  gate.open();
  await firstTick;
  // Once the first tick finished, the next one runs normally.
  await h.scheduler.fire();
  assert.equal(execCalls, 2);
});
