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
function fakeAdapter(): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as unknown as { agent: string }).agent = "stub";
  (e as unknown as { start: () => Promise<void> }).start = async () => {};
  (e as unknown as { send: () => Promise<void> }).send = async () => {};
  (e as unknown as { cancel: () => Promise<void> }).cancel = async () => {};
  (e as unknown as { kill: () => Promise<void> }).kill = async () => {};
  return e;
}

/**
 * SPEC-17 P2: a stream of per-token deltas must NOT re-broadcast the full
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

// ── SPEC-32 T6: github.budget broadcast + commands ────────────────────────────

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

test("a connecting client receives a github.budget event (SPEC-32)", async () => {
  await withBudgetServer(async ({ nextEvent }) => {
    const env = await nextEvent((e) => e.t === "event" && e.kind === "github.budget");
    const budget = (env as { budget?: Record<string, unknown> }).budget!;
    assert.ok(budget, "the event carries a budget payload");
    assert.ok("buckets" in budget && "level" in budget, "budget has the frozen wire shape");
    assert.ok(Array.isArray(budget.history) && (budget.history as unknown[]).length === 60, "60 history slots");
    assert.ok(budget.stats && typeof (budget.stats as { execs?: unknown }).execs === "number", "stats present");
  });
});

test("github.refresh acks and re-broadcasts the budget (SPEC-32)", async () => {
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

test("github.watch {watching:true} acks and pushes a snapshot at once (SPEC-32)", async () => {
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

test("github.watch {watching:false} acks and unregisters the watcher (SPEC-32)", async () => {
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

test("the fast snapshot goes to the watcher only, not to every client (SPEC-32)", async () => {
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

test("github.pause {paused:true} flips the level to paused (SPEC-32)", async () => {
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
