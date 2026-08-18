import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { startWsServer } from "./server.js";
import { SessionManager } from "./manager.js";
import { loadOrCreateCert } from "./pairing/cert.js";
import { DeviceRegistry } from "./pairing/registry.js";
import { PROTOCOL_VERSION } from "./protocol.js";
import type { Envelope } from "./protocol.js";
import { EventEmitter } from "node:events";
import type { AgentAdapter } from "./adapters/adapter.js";

/** Minimal in-process adapter whose events can be driven from the test. */
function fakeAdapter(pid?: number): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as unknown as { agent: string }).agent = "stub";
  // SPEC-performance-metrics-dashboard: acp/codex expose `agentPid` structurally (it is deliberately not on
  // the AgentAdapter contract). A double without it makes every metrics agent-row
  // test vacuous, so opt in explicitly where a test needs a pid.
  if (pid !== undefined) (e as unknown as { agentPid: number }).agentPid = pid;
  (e as unknown as { start: () => Promise<void> }).start = async () => {};
  (e as unknown as { send: () => Promise<void> }).send = async () => {};
  (e as unknown as { cancel: () => Promise<void> }).cancel = async () => {};
  (e as unknown as { kill: () => Promise<void> }).kill = async () => {};
  return e;
}

/**
 * SPEC-server-hotpath-and-state P2: a stream of per-token deltas must NOT re-broadcast the full
 * sessions snapshot (the O(clients × sessions) hot-path cliff), while a DTO-
 * visible change (status) still does. Drives a real WS server end-to-end and
 * counts `sessions.snapshot` frames on the wire.
 */
test("streaming deltas do not re-broadcast the sessions snapshot; a status change does (P2)", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-srv-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;

  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  const manager = new SessionManager({ projects: [project], adapterFactory: () => fakeAdapter() });
  const projectId = manager.listProjects()[0].id;
  const session = await manager.spawnPiSession(projectId);

  // Wire sessions created before startWsServer via allSessions().
  const server = startWsServer({ host: "127.0.0.1", port: 0, manager, cert, registry, trustLocalhost: true });
  await new Promise<void>((r) => server.https.on("listening", () => r()));
  const port = (server.https.address() as AddressInfo).port;

  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  let snapshotCount = 0;
  const pongs: string[] = [];
  ws.on("message", (raw) => {
    const env = JSON.parse(raw.toString()) as Envelope;
    if (env.t === "event" && env.kind === "sessions.snapshot") snapshotCount++;
    if (env.t === "pong") pongs.push(env.id);
  });

  const ping = (id: string) =>
    new Promise<void>((resolve, reject) => {
      const before = pongs.length;
      const timer = setInterval(() => {
        if (pongs.length > before && pongs.includes(id)) {
          clearInterval(timer);
          clearTimeout(timeout);
          resolve();
        }
      }, 5);
      // A missing pong must not leave the promise + interval alive forever
      // (hanging the whole test run). Bound the barrier and fail loudly.
      const timeout = setTimeout(() => {
        clearInterval(timer);
        reject(new Error(`ping ${id} timed out waiting for pong`));
      }, 5000);
      ws.send(JSON.stringify({ v: PROTOCOL_VERSION, t: "ping", id, ts: Date.now() }));
    });

  try {
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });
    // Barrier: the trusted-local client receives the initial snapshots on
    // connect. Flush them before counting.
    await ping("p0");
    const baseline = snapshotCount;
    assert.ok(baseline >= 1, "client receives an initial sessions.snapshot");

    // A stream of N per-token deltas.
    for (let i = 0; i < 25; i++) {
      session.adapter.emit("event", { ts: i, kind: "agent.message.delta", payload: { text: "x" } });
    }
    await ping("p1");
    assert.equal(snapshotCount, baseline, "per-token deltas must NOT re-broadcast the sessions snapshot");

    // A status transition IS a DTO-visible change → exactly one broadcast.
    session.adapter.emit("status", "running");
    await ping("p2");
    assert.equal(snapshotCount, baseline + 1, "a status change broadcasts exactly one sessions.snapshot");
  } finally {
    ws.close();
    await new Promise<void>((r) => server.wss.close(() => r()));
    await new Promise<void>((r) => server.https.close(() => r()));
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});

// ── SPEC-github-gateway-and-budget T6: github.budget broadcast + commands ────────────────────────────

import { createGithubGateway, type ExecResult } from "./github/gateway.js";

/** A fake `gh` exec: healthy rate_limit, empty for everything else. */
function healthyExec(): (cmd: string, args: string[]) => Promise<ExecResult> {
  return async (_cmd, args) => {
    if (args[0] === "api" && args[1] === "rate_limit") {
      return {
        code: 0,
        stdout: JSON.stringify({
          resources: {
            core: { limit: 5000, remaining: 5000, reset: 9_999_999_999 },
            graphql: { limit: 5000, remaining: 5000, reset: 9_999_999_999 },
          },
        }),
        stderr: "",
      };
    }
    return { code: 0, stdout: "[]", stderr: "" };
  };
}

/** Boot a server whose manager uses an injected fake gateway (no subprocess). */
async function withBudgetServer(
  run: (ctx: {
    ws: WebSocket;
    send: (frame: Record<string, unknown>) => void;
    nextEvent: (pred: (env: Envelope) => boolean) => Promise<Envelope>;
  }) => Promise<void>,
): Promise<void> {
  const home = mkdtempSync(join(tmpdir(), "makit-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-srv-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  const gateway = createGithubGateway({
    exec: healthyExec(),
    setTimer: () => ({ unref() {} }), // periodic refresh never fires in tests
    clearTimer: () => {},
  });
  const manager = new SessionManager({ projects: [project], adapterFactory: () => fakeAdapter(), gateway });
  const server = startWsServer({ host: "127.0.0.1", port: 0, manager, cert, registry, trustLocalhost: true });
  await new Promise<void>((r) => server.https.on("listening", () => r()));
  const port = (server.https.address() as AddressInfo).port;
  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });

  const pending: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void }> = [];
  const buffered: Envelope[] = [];
  ws.on("message", (raw) => {
    const env = JSON.parse(raw.toString()) as Envelope;
    const i = pending.findIndex((p) => p.pred(env));
    if (i >= 0) pending.splice(i, 1)[0].resolve(env);
    else buffered.push(env);
  });
  const nextEvent = (pred: (env: Envelope) => boolean): Promise<Envelope> => {
    const hit = buffered.findIndex(pred);
    if (hit >= 0) return Promise.resolve(buffered.splice(hit, 1)[0]);
    return new Promise<Envelope>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("timed out waiting for event")), 5000);
      pending.push({ pred, resolve: (e) => (clearTimeout(t), resolve(e)) });
    });
  };
  const send = (frame: Record<string, unknown>) => ws.send(JSON.stringify({ v: PROTOCOL_VERSION, ...frame }));

  try {
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });
    await run({ ws, send, nextEvent });
  } finally {
    ws.close();
    await new Promise<void>((r) => server.wss.close(() => r()));
    await new Promise<void>((r) => server.https.close(() => r()));
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
}

test("a connecting client receives a github.budget event (SPEC-github-gateway-and-budget)", async () => {
  await withBudgetServer(async ({ nextEvent }) => {
    const env = await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    const budget = (env as { budget?: Record<string, unknown> }).budget!;
    assert.ok(budget, "the event carries a budget payload");
    assert.ok("buckets" in budget && "level" in budget, "budget has the frozen wire shape");
    assert.ok(Array.isArray(budget.history) && (budget.history as unknown[]).length === 60, "60 history slots");
    assert.ok(budget.stats && typeof (budget.stats as { execs?: unknown }).execs === "number", "stats present");
  });
});

test("github.refresh acks and re-broadcasts the budget (SPEC-github-gateway-and-budget)", async () => {
  await withBudgetServer(async ({ send, nextEvent }) => {
    // Flush the connect-time budget event first.
    await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    send({ t: "cmd", id: "r1", kind: "github.refresh" });
    const ack = await nextEvent((e) => e.t === "ack" && e.id === "r1");
    assert.ok(ack, "github.refresh acks");
    const budget = await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    assert.ok(budget, "github.refresh re-broadcasts the budget");
  });
});

test("github.watch {watching:true} acks and pushes a snapshot at once (SPEC-github-gateway-and-budget)", async () => {
  await withBudgetServer(async ({ send, nextEvent }) => {
    await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    send({ t: "cmd", id: "w1", kind: "github.watch", watching: true });
    assert.ok(await nextEvent((e) => e.t === "ack" && e.id === "w1"), "github.watch acks");
    // Opening the panel must not wait out an interval for its first fresh read.
    assert.ok(
      await nextEvent((e) => e.t === "event" && e.kind === "github.budget"),
      "watching pushes a budget snapshot immediately",
    );
  });
});

test("github.watch {watching:false} acks and unregisters the watcher (SPEC-github-gateway-and-budget)", async () => {
  await withBudgetServer(async ({ send, nextEvent }) => {
    await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    send({ t: "cmd", id: "w1", kind: "github.watch", watching: true });
    await nextEvent((e) => e.t === "ack" && e.id === "w1");
    await nextEvent((e) => e.t === "event" && e.kind === "github.budget");

    send({ t: "cmd", id: "w2", kind: "github.watch", watching: false });
    assert.ok(await nextEvent((e) => e.t === "ack" && e.id === "w2"), "unwatch acks");

    // Prove the client was really unregistered rather than just acked, without
    // reaching into the server for a timer: the immediate read fires only on the
    // 0 -> 1 watcher transition (`add` returns early for a known watcher). So a
    // second `watching:true` yielding a fresh snapshot can only mean the unwatch
    // took effect. Whether the *interval* stops is covered by budget_watch.test.
    send({ t: "cmd", id: "w3", kind: "github.watch", watching: true });
    await nextEvent((e) => e.t === "ack" && e.id === "w3");
    assert.ok(
      await nextEvent((e) => e.t === "event" && e.kind === "github.budget"),
      "re-watching reads immediately again, so the watcher had been dropped",
    );
  });
});

test("the fast snapshot goes to the watcher only, not to every client (SPEC-github-gateway-and-budget)", async () => {
  await withBudgetServer(async ({ ws, send, nextEvent }) => {
    await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    // A second client with no panel open — a paired phone has no budget UI at all.
    const other = new WebSocket(ws.url, { rejectUnauthorized: false });
    const otherBudgets: Envelope[] = [];
    let sawFirst: (() => void) | undefined;
    const firstSnapshot = new Promise<void>((resolve) => (sawFirst = resolve));
    other.on("message", (raw) => {
      const env = JSON.parse(raw.toString()) as Envelope;
      if (env.t === "event" && env.kind === "github.budget") {
        otherBudgets.push(env);
        sawFirst?.();
      }
    });
    try {
      await new Promise<void>((resolve, reject) => {
        other.on("open", () => resolve());
        other.on("error", reject);
      });
      // Wait for its connect-time snapshot by event, not by clock: a fixed sleep
      // either flakes on a slow machine or leaks that snapshot into the assertion.
      await firstSnapshot;
      otherBudgets.length = 0;

      send({ t: "cmd", id: "w1", kind: "github.watch", watching: true });
      await nextEvent((e) => e.t === "ack" && e.id === "w1");
      await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
      // The watcher got its immediate snapshot; the bystander must have got none.
      assert.deepEqual(otherBudgets, [], "a non-watching client is not pushed the fast snapshot");
    } finally {
      other.close();
    }
  });
});

test("github.pause {paused:true} flips the level to paused (SPEC-github-gateway-and-budget)", async () => {
  await withBudgetServer(async ({ send, nextEvent }) => {
    // Ensure the budget is measured (so 'paused' is reachable), then pause.
    await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    send({ t: "cmd", id: "rf", kind: "github.refresh" });
    await nextEvent((e) => e.t === "ack" && e.id === "rf");
    send({ t: "cmd", id: "p1", kind: "github.pause", paused: true });
    await nextEvent((e) => e.t === "ack" && e.id === "p1");
    const paused = await nextEvent(
      (e) =>
        e.t === "event" &&
        e.kind === "github.budget" &&
        (e as { budget?: { level?: string } }).budget?.level === "paused",
    );
    assert.ok(paused, "pausing flips the budget level to paused");
  });
});

// ── SPEC-performance-metrics-dashboard T6: metrics.sample wire event + metrics.watch command ─────────────

/** A canned `ps` table whose only row is this process (so `app` can resolve). */
function fakeMetricsExec(): (
  cmd: string,
  args: string[],
  cwd?: string,
  timeoutMs?: number,
) => Promise<{ code: number; stdout: string; stderr: string }> {
  return async () => ({
    code: 0,
    stdout: `${process.pid} 1 50000 0:01.00 node`,
    stderr: "",
  });
}

/**
 * Boot a server with the metrics collector's timer + exec seams injected, so a
 * sample can be driven deterministically. `driveTick()` fires the collector's
 * captured timer callback once; `lastIntervalMs()` reveals the armed cadence.
 */
async function withMetricsServer(
  run: (ctx: {
    server: ReturnType<typeof startWsServer>;
    manager: SessionManager;
    port: number;
    connect: () => Promise<MetricsConn>;
    driveTick: () => Promise<void>;
    lastIntervalMs: () => number | null;
  }) => Promise<void>,
  opts: { background?: boolean } = {},
): Promise<void> {
  const home = mkdtempSync(join(tmpdir(), "makit-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-srv-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  // Use this process's own pid: it genuinely exists in the `ps` table, so agent rows
  // are actually populated and assertions about them are not vacuous.
  const manager = new SessionManager({
    projects: [project],
    adapterFactory: () => fakeAdapter(process.pid),
  });

  let tickFn: (() => void | Promise<void>) | null = null;
  let armedMs: number | null = null;
  const server = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry,
    trustLocalhost: true,
    metrics: {
      exec: fakeMetricsExec(),
      now: () => Date.now(),
      setTimer: (fn, ms) => {
        tickFn = fn;
        armedMs = ms;
        return 1;
      },
      clearTimer: () => {},
      enabled: opts.background ?? true,
    },
  });
  await new Promise<void>((r) => server.https.on("listening", () => r()));
  const port = (server.https.address() as AddressInfo).port;

  const conns: MetricsConn[] = [];
  const connect = async (): Promise<MetricsConn> => {
    const c = await openMetricsConn(port);
    conns.push(c);
    return c;
  };
  const driveTick = async (): Promise<void> => {
    assert.ok(tickFn, "the collector armed a timer");
    await tickFn!();
  };

  try {
    await run({ server, manager, port, connect, driveTick, lastIntervalMs: () => armedMs });
  } finally {
    for (const c of conns) c.ws.close();
    await new Promise<void>((r) => server.wss.close(() => r()));
    await new Promise<void>((r) => server.https.close(() => r()));
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
}

interface MetricsConn {
  ws: WebSocket;
  send: (frame: Record<string, unknown>) => void;
  nextEvent: (pred: (env: Envelope) => boolean) => Promise<Envelope>;
  metricsFrames: Envelope[];
  /** Every frame received, for assertions about what must NOT be sent. */
  allFrames: Envelope[];
  ping: () => Promise<void>;
}

async function openMetricsConn(port: number): Promise<MetricsConn> {
  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  const pending: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void }> = [];
  const buffered: Envelope[] = [];
  const metricsFrames: Envelope[] = [];
  const allFrames: Envelope[] = [];
  const pongs = new Set<string>();
  ws.on("message", (raw) => {
    const env = JSON.parse(raw.toString()) as Envelope;
    allFrames.push(env);
    if (env.t === "event" && env.kind === "metrics.sample") metricsFrames.push(env);
    if (env.t === "pong") pongs.add(env.id);
    const i = pending.findIndex((p) => p.pred(env));
    if (i >= 0) pending.splice(i, 1)[0].resolve(env);
    else buffered.push(env);
  });
  const nextEvent = (pred: (env: Envelope) => boolean): Promise<Envelope> => {
    const hit = buffered.findIndex(pred);
    if (hit >= 0) return Promise.resolve(buffered.splice(hit, 1)[0]);
    return new Promise<Envelope>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error("timed out waiting for event")), 5000);
      pending.push({ pred, resolve: (e) => (clearTimeout(t), resolve(e)) });
    });
  };
  const send = (frame: Record<string, unknown>) =>
    ws.send(JSON.stringify({ v: PROTOCOL_VERSION, ...frame }));
  let pingSeq = 0;
  const ping = async (): Promise<void> => {
    const id = `ping-${pingSeq++}`;
    send({ t: "ping", id, ts: Date.now() });
    await nextEvent((e) => e.t === "pong" && e.id === id);
  };
  await new Promise<void>((resolve, reject) => {
    ws.on("open", () => resolve());
    ws.on("error", reject);
  });
  return { ws, send, nextEvent, metricsFrames, allFrames, ping };
}

test("metrics.watch {on:true} acks then a sample WITH history arrives; the next has none (SPEC-performance-metrics-dashboard)", async () => {
  await withMetricsServer(async ({ connect, driveTick }) => {
    const c = await connect();
    // Prime the ring so the first watched frame carries history.
    await driveTick();
    await c.nextEvent((e) => e.kind === "metrics.sample"); // the coarse frame
    c.metricsFrames.length = 0;

    c.send({ t: "cmd", id: "w1", kind: "metrics.watch", on: true });
    await c.nextEvent((e) => e.t === "ack" && e.id === "w1");

    const first = await c.nextEvent(
      (e) => e.kind === "metrics.sample" && Array.isArray((e as { history?: unknown }).history),
    );
    assert.ok((first as { history?: unknown[] }).history!.length >= 1, "first watched frame carries history");
    assert.ok((first as { sample?: unknown }).sample, "and a sample");

    c.metricsFrames.length = 0;
    await driveTick();
    const second = await c.nextEvent((e) => e.kind === "metrics.sample");
    assert.equal((second as { history?: unknown }).history, undefined, "subsequent samples carry no history");
  });
});

test("a non-watching authed client receives coarse samples but not watched ones (SPEC-performance-metrics-dashboard)", async () => {
  await withMetricsServer(async ({ connect, driveTick }) => {
    const watcher = await connect();
    const idle = await connect();

    // No watchers yet → coarse cadence → both clients get the frame.
    await driveTick();
    await watcher.nextEvent((e) => e.kind === "metrics.sample");
    await idle.nextEvent((e) => e.kind === "metrics.sample");

    // One client starts watching → cadence goes fine (1 Hz).
    watcher.send({ t: "cmd", id: "w1", kind: "metrics.watch", on: true });
    await watcher.nextEvent((e) => e.t === "ack" && e.id === "w1");
    // Drain the priming history frame the watcher just received.
    await watcher.nextEvent((e) => e.kind === "metrics.sample");

    watcher.metricsFrames.length = 0;
    idle.metricsFrames.length = 0;
    await driveTick();
    await watcher.nextEvent((e) => e.kind === "metrics.sample");
    // A round-trip proves the idle client has processed everything up to now.
    await idle.ping();
    assert.equal(idle.metricsFrames.length, 0, "the idle client got no watched (fine) sample");
    assert.equal(watcher.metricsFrames.length, 1, "the watcher got exactly the fine sample");
  });
});

test("socket close clears the watcher and the cadence returns to idle (SPEC-performance-metrics-dashboard leak guard)", async () => {
  await withMetricsServer(async ({ connect, driveTick, lastIntervalMs }) => {
    const c = await connect();
    await driveTick();
    c.send({ t: "cmd", id: "w1", kind: "metrics.watch", on: true });
    await c.nextEvent((e) => e.t === "ack" && e.id === "w1");
    assert.equal(lastIntervalMs(), 1000, "watching arms the 1 Hz cadence");

    c.ws.close();
    // Wait for the server to observe the close and re-arm.
    await new Promise<void>((r) => c.ws.on("close", () => r()));
    for (let i = 0; i < 50 && lastIntervalMs() !== 5000; i++) {
      await new Promise((r) => setTimeout(r, 10));
    }
    assert.equal(lastIntervalMs(), 5000, "a closed panel drops the cadence back to 5 s idle");
  });
});

test("hello {pid} over loopback is accepted and colours the app row (SPEC-performance-metrics-dashboard decision 6)", async () => {
  await withMetricsServer(async ({ connect, driveTick }) => {
    const c = await connect();
    c.send({ t: "hello", id: "h1", pid: process.pid });
    await c.nextEvent((e) => e.t === "hello.ack" && e.id === "h1");
    await driveTick();
    const frame = await c.nextEvent((e) => e.kind === "metrics.sample");
    const sample = (frame as unknown as { sample: { app: { pid: number } | null } }).sample;
    assert.ok(sample.app, "a loopback-reported pid produces an app row");
    assert.equal(sample.app!.pid, process.pid);
  });
});

test("REGRESSION: driving samples never grows any session's event log (SPEC-performance-metrics-dashboard decision 5)", async () => {
  await withMetricsServer(async ({ connect, driveTick, manager }) => {
    const projectId = manager.listProjects()[0].id;
    const session = await manager.spawnPiSession(projectId);
    const baseline = session.events.length;

    const c = await connect();
    c.send({ t: "cmd", id: "w1", kind: "metrics.watch", on: true });
    await c.nextEvent((e) => e.t === "ack" && e.id === "w1");
    for (let i = 0; i < 5; i++) await driveTick();

    assert.equal(session.events.length, baseline, "no metrics sample entered the append-only session log");
    for (const s of manager.allSessions()) {
      assert.ok(
        !s.events.some((ev) => ev.kind.startsWith("metrics.")),
        "no session event carries a metrics.* kind",
      );
    }
    // The above two assertions only inspect the log. A future edit that routed
    // samples through SubscriptionHub.fanout would keep the log clean and still be
    // wrong — fanout wraps events as `session.event` frames, which the app replays
    // as transcript content. Assert on what actually went over the wire instead of
    // trusting the log alone (review finding: the log-only guard was half-theatre).
    const sessionEventFrames = c.allFrames.filter(
      (f) => f.t === "event" && f.kind === "session.event",
    );
    for (const f of sessionEventFrames) {
      const ev = (f as { event?: { kind?: string } }).event;
      assert.ok(
        !(ev?.kind ?? "").startsWith("metrics."),
        "a metrics sample must never be delivered as a session.event",
      );
    }
  });
});

test("an exited session contributes no pid — a reused pid must not be attributed to it (SPEC-performance-metrics-dashboard)", async () => {
  await withMetricsServer(async ({ connect, driveTick, manager }) => {
    const projectId = manager.listProjects()[0].id;
    const session = await manager.spawnPiSession(projectId);
    const c = await connect();
    c.send({ t: "cmd", id: "w1", kind: "metrics.watch", on: true });
    await c.nextEvent((e) => e.t === "ack" && e.id === "w1");

    // Mark the session exited. Its old child pid is still on the adapter, and the
    // OS recycles pids — sampling it would attribute a stranger's process tree to
    // a dead agent.
    session.backfill([{ ts: Date.now(), kind: "session.status", payload: { status: "exited" } }]);
    assert.equal(session.status, "exited", "precondition: the session really is exited");
    c.metricsFrames.length = 0;
    await driveTick();
    await c.nextEvent((e) => e.kind === "metrics.sample");

    const sample = c.metricsFrames.at(-1)?.sample as { agents: Array<{ sessionId: string }> };
    assert.ok(
      !sample.agents.some((a) => a.sessionId === session.id),
      "an exited session must not appear as a live agent row",
    );
  });
});

test("a non-integer pid over loopback is rejected (SPEC-performance-metrics-dashboard decision 6)", async () => {
  // 0, negatives, fractions, NaN and Infinity are all `typeof "number"`. Without a
  // safe-integer check each became `appPid` and the collector rendered a plausible
  // app row for a process that cannot exist.
  for (const bad of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    await withMetricsServer(async ({ connect, driveTick }) => {
      const c = await connect();
      c.send({ t: "hello", id: "h1", pid: bad });
      await c.nextEvent((e) => e.t === "hello.ack" && e.id === "h1");
      c.send({ t: "cmd", id: "w", kind: "metrics.watch", on: true });
      await c.nextEvent((e) => e.t === "ack" && e.id === "w");
      c.metricsFrames.length = 0;
      await driveTick();
      await c.nextEvent((e) => e.kind === "metrics.sample");
      const sample = c.metricsFrames.at(-1)?.sample as { app: unknown };
      assert.equal(sample.app, null, `pid ${String(bad)} must not produce an app row`);
    });
  }
});

// ── SPEC-open-ports: ports.watch leak guard — a socket close clears watchingPorts and
// recounts the watchers, disarming the scanner (server.ts close handler). ─────
test("SPEC-open-ports: a socket close clears watchingPorts and disarms the port scanner", async () => {
  const home = mkdtempSync(join(tmpdir(), "makit-home-"));
  const project = mkdtempSync(join(tmpdir(), "makit-srv-proj-"));
  const prevHome = process.env.MAKIT_HOME;
  process.env.MAKIT_HOME = home;
  const cert = await loadOrCreateCert();
  const registry = new DeviceRegistry();
  const manager = new SessionManager({ projects: [project], adapterFactory: () => fakeAdapter() });

  let armed = 0;
  let cleared = 0;
  const server = startWsServer({
    host: "127.0.0.1",
    port: 0,
    manager,
    cert,
    registry,
    trustLocalhost: true,
    ports: {
      // Deterministic + subprocess-free: an empty scan is enough to exercise the
      // watch lifecycle. A fake timer lets us observe arm/disarm precisely.
      exec: async () => ({ code: 0, stdout: "", stderr: "" }),
      setTimer: () => {
        armed++;
        return { id: armed };
      },
      clearTimer: () => {
        cleared++;
      },
    },
  });
  await new Promise<void>((r) => server.https.on("listening", () => r()));
  const port = (server.https.address() as AddressInfo).port;

  const ws = new WebSocket(`wss://127.0.0.1:${port}`, { rejectUnauthorized: false });
  const acks: string[] = [];
  ws.on("message", (raw) => {
    const env = JSON.parse(raw.toString()) as Envelope;
    if (env.t === "ack") acks.push(env.id);
  });
  try {
    await new Promise<void>((resolve, reject) => {
      ws.on("open", () => resolve());
      ws.on("error", reject);
    });

    ws.send(JSON.stringify({ v: PROTOCOL_VERSION, t: "cmd", id: "w1", kind: "ports.watch", on: true }));
    for (let i = 0; i < 100 && !acks.includes("w1"); i++) await new Promise((r) => setTimeout(r, 10));
    assert.ok(acks.includes("w1"), "the watch was acked");
    assert.equal(armed, 1, "0→1 arms the scan timer");

    ws.close();
    await new Promise<void>((r) => ws.on("close", () => r()));
    // Wait for the server to observe the close and recompute the watcher count.
    for (let i = 0; i < 100 && cleared < 1; i++) await new Promise((r) => setTimeout(r, 10));
    assert.equal(cleared, 1, "the close cleared watchingPorts and disarmed the scanner (1→0)");
  } finally {
    ws.close();
    await new Promise<void>((r) => server.wss.close(() => r()));
    await new Promise<void>((r) => server.https.close(() => r()));
    if (prevHome === undefined) delete process.env.MAKIT_HOME;
    else process.env.MAKIT_HOME = prevHome;
    rmSync(home, { recursive: true, force: true });
    rmSync(project, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Batched fan-out over a real socket (see SubscriptionHub + protocol.ts).
// ---------------------------------------------------------------------------

test("a client that announces `batch` gets one frame per window; one that does not gets one per event", async () => {
  await withMetricsServer(async ({ connect, manager }) => {
    const projectId = manager.listProjects()[0].id;
    const session = await manager.spawnPiSession(projectId);

    // Two devices on one server: a new app, and an older client (or a CLI).
    const batching = await connect();
    batching.send({ t: "hello", id: "h1", batch: true });
    await batching.nextEvent((e) => e.t === "hello.ack" && e.id === "h1");
    const perEvent = await connect();
    perEvent.send({ t: "hello", id: "h2" });
    await perEvent.nextEvent((e) => e.t === "hello.ack" && e.id === "h2");
    batching.allFrames.length = 0;
    perEvent.allFrames.length = 0;

    // A turn streams six tokens inside one window.
    for (let i = 0; i < 6; i++) {
      session.adapter.emit("event", {
        ts: Date.now(),
        kind: "agent.message.delta",
        payload: { msgId: "m1", chunk: `c${i}` },
      });
    }

    const batch = await batching.nextEvent((e) => e.kind === "session.events");
    const events = (batch as unknown as { events: Array<{ payload: { chunk: string } }> }).events;
    assert.deepEqual(
      events.map((e) => e.payload.chunk),
      ["c0", "c1", "c2", "c3", "c4", "c5"],
      "one frame carried the whole window, in order",
    );
    assert.equal(
      batching.allFrames.filter((f) => f.kind === "session.event").length,
      0,
      "and no per-event frame went to it",
    );

    // The other client received six single-event frames and no batch.
    for (let i = 0; i < 6; i++) {
      await perEvent.nextEvent(
        (e) =>
          e.kind === "session.event" &&
          (e as unknown as { event: { payload: { chunk: string } } }).event.payload.chunk === `c${i}`,
      );
    }
    assert.equal(
      perEvent.allFrames.filter((f) => f.kind === "session.events").length,
      0,
      "an older client never sees a batch frame",
    );
  });
});

test("an ack never overtakes the events fanned out before it", async () => {
  await withMetricsServer(async ({ connect, manager }) => {
    const projectId = manager.listProjects()[0].id;
    const session = await manager.spawnPiSession(projectId);

    const c = await connect();
    c.send({ t: "hello", id: "h1", batch: true });
    await c.nextEvent((e) => e.t === "hello.ack" && e.id === "h1");
    c.allFrames.length = 0;

    session.adapter.emit("event", {
      ts: Date.now(),
      kind: "agent.message.delta",
      payload: { msgId: "m1", chunk: "first" },
    });
    // A command right behind it: its ack must arrive AFTER the pending batch, or
    // the app reads a `sub` replay as live events and drops the history.
    c.send({ t: "ping", id: "p1", ts: Date.now() });
    await c.nextEvent((e) => e.t === "pong" && e.id === "p1");

    const kinds = c.allFrames.map((f) => f.kind ?? f.t);
    assert.deepEqual(
      kinds.filter((k) => k === "session.events" || k === "pong"),
      ["session.events", "pong"],
    );
  });
});
