/**
 * Re-attach hardening: the paths a second reviewer proved were wrong.
 *
 * Separate file, on purpose. `manager.test.ts` sits at ~82 top-level tests and
 * the node:test runner stops scheduling after them: any test appended there is
 * reported `cancelled` and silently never runs (see the note in the PR). These
 * would have been starved.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { SessionManager } from "./manager.js";
import { SqliteEventStore } from "./storage/sqlite_event_store.js";
import type { AgentAdapter, SpawnOpts } from "./adapters/adapter.js";

/** A stub adapter that records the SpawnOpts it was started with. */
function stubAdapter(started: SpawnOpts[]): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "stub";
  (e as any).capabilities = { resume: true, load: false, list: true, delete: true, fork: false };
  (e as any).agentSessionId = undefined;
  (e as any).start = async (opts: SpawnOpts) => {
    started.push(opts);
    (e as any).agentSessionId = opts.resumeAgentSessionId ?? `stub-${opts.sessionId ?? "x"}`;
  };
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  return e;
}

/** Seed the store with a cold session as a prior server run would have left it. */
function seedColdSession(store: SqliteEventStore, id: string, agentSessionId: string) {
  store.saveSession({
    id,
    projectId: "proj-x",
    agent: "pi",
    title: "prior work",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 2,
    lastPreview: "old task",
    agentSessionId,
  });
  store.append(id, { ts: 2, kind: "user.message", payload: { text: "old task" } });
}

test("ensureLive waits for an in-flight re-attach instead of returning early", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-gate", "pi-6");
  const started: SpawnOpts[] = [];
  // A start that simply takes a while. Deliberately NOT a manual gate: a gate a
  // failed assertion leaves unreleased hangs the entire test file.
  const SLOW_MS = 60;
  const slow = stubAdapter(started) as any;
  const inner = slow.start;
  slow.start = async (opts: SpawnOpts) => {
    await new Promise((r) => setTimeout(r, SLOW_MS));
    await inner(opts);
  };
  const mgr = new SessionManager({
    projects: [],
    store,
    adapterFactory: () => slow as AgentAdapter,
  });

  try {
    // `doReattachSession` installs the new adapter BEFORE `start()` resolves, so
    // a racing caller must not be fooled by the session no longer looking cold.
    // Returning early is what let `send.message` hand a prompt to an adapter
    // that had not finished initialising (ACP rejects that: "send before start").
    const first = mgr.ensureLive("sess-gate");
    await new Promise((r) => setTimeout(r, 5));
    const t0 = Date.now();
    await mgr.ensureLive("sess-gate");
    const waited = Date.now() - t0;
    await first;

    assert.ok(
      waited >= SLOW_MS / 2,
      `the racing caller must block until the resume finishes (waited only ${waited}ms)`,
    );
    assert.equal(started.length, 1, "one agent started");
  } finally {
    store.close();
  }
});

test("a failed re-attach stops the half-started agent and leaves the session exited", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-halfstart", "pi-7");
  const kills: string[] = [];
  const mgr = new SessionManager({
    projects: [],
    store,
    adapterFactory: () => {
      const e = stubAdapter([]) as any;
      e.kill = async () => {
        kills.push("kill");
      };
      e.start = async () => {
        // Realistic: the child spawned and handshook (so the session already saw
        // `idle`), then model configuration blew up.
        e.emit("status", "idle");
        throw new Error("model configuration failed");
      };
      return e as AgentAdapter;
    },
  });

  try {
    await mgr.ensureLive("sess-halfstart");
    assert.equal(kills.length, 1, "the half-started agent was stopped, not leaked");
    assert.equal(
      mgr.getSession("sess-halfstart")!.status,
      "exited",
      "status must not be left on the `idle` the failed start emitted",
    );
  } finally {
    store.close();
  }
});

test("ensureLive swallows a non-Error failure instead of rejecting", async () => {
  const store = new SqliteEventStore();
  seedColdSession(store, "sess-nonerror", "pi-8");
  const mgr = new SessionManager({
    projects: [],
    store,
    adapterFactory: () => {
      const e = stubAdapter([]) as any;
      // Not every rejection is an Error. `case "sub"` calls ensureLive as `void`,
      // so a throw from its own catch block would become exactly the unhandled
      // rejection this design exists to prevent.
      e.start = async () => {
        throw null;
      };
      return e as AgentAdapter;
    },
  });

  try {
    await assert.doesNotReject(() => mgr.ensureLive("sess-nonerror"));
  } finally {
    store.close();
  }
});
