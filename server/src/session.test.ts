import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { Session, type SessionLifecycle } from "./session.js";
import type { AgentAdapter, AdapterEvent } from "./adapters/adapter.js";

function fakeAdapter(): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "pi";
  (e as any).start = async () => {};
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  return e;
}

test("backfill seeds the event log without emitting, then live events continue the seq", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  const emitted: number[] = [];
  session.on("event", (ev) => emitted.push(ev.seq));

  const history: AdapterEvent[] = [
    { ts: 1, kind: "user.message", payload: { text: "hi" } },
    { ts: 2, kind: "agent.message", payload: { text: "hello back" } },
  ];
  session.backfill(history);

  // Backfill populates events but does NOT emit (replayed on sub instead).
  assert.equal(emitted.length, 0);
  assert.equal(session.events.length, 2);
  assert.deepEqual(session.events.map((e) => e.seq), [1, 2]);
  assert.equal(session.events[0].sessionId, session.id);
  assert.equal(session.lastPreview, "hello back");

  // A subsequent live event continues the seq space (3, not 1).
  session.adapter.emit("event", { ts: 3, kind: "user.message", payload: { text: "next" } });
  assert.deepEqual(emitted, [3]);
  assert.equal(session.events.length, 3);
});

test("setTitle updates the title, emits titleChanged, and dedups empty/unchanged", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  const changes: string[] = [];
  session.on("titleChanged", (t) => changes.push(t));

  // First real title → changes.
  assert.equal(session.setTitle("Fix the parser"), true);
  assert.equal(session.title, "Fix the parser");

  // Trims surrounding whitespace.
  assert.equal(session.setTitle("  Fix the parser  "), false); // same after trim
  assert.equal(session.setTitle("Rename me"), true);

  // Empty / whitespace-only is ignored.
  assert.equal(session.setTitle("   "), false);
  assert.equal(session.setTitle(""), false);
  assert.equal(session.title, "Rename me");

  assert.deepEqual(changes, ["Fix the parser", "Rename me"]);
});

test("adapter 'title' events retitle the session", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });
  const changes: string[] = [];
  session.on("titleChanged", (t) => changes.push(t));

  session.adapter.emit("title", "auto-named from pi");
  assert.equal(session.title, "auto-named from pi");
  assert.deepEqual(changes, ["auto-named from pi"]);
});

test("metaChanged fires on preview/status/title changes but NOT on streaming deltas (P2)", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  let meta = 0;
  session.on("metaChanged", () => meta++);

  // A stream of N per-token deltas must NOT trigger the sessions-snapshot
  // fan-out (that is the O(clients × sessions) hot-path cliff P2 removes).
  for (let i = 0; i < 20; i++) {
    session.adapter.emit("event", { ts: i, kind: "agent.message.delta", payload: { text: "x" } });
  }
  session.adapter.emit("event", { ts: 21, kind: "agent.thinking.delta", payload: { text: "t" } });
  session.adapter.emit("event", { ts: 22, kind: "tool.call.delta", payload: {} });
  assert.equal(meta, 0, "streaming deltas must not change session-list meta");

  // A finalized agent.message changes the preview → one meta change.
  session.adapter.emit("event", { ts: 23, kind: "agent.message", payload: { text: "done" } });
  assert.equal(meta, 1);

  // A status transition changes the DTO → one meta change.
  session.adapter.emit("status", "running");
  assert.equal(meta, 2);

  // A title change is DTO-visible → one meta change.
  session.setTitle("Renamed");
  assert.equal(meta, 3);

  // An unchanged title does NOT emit.
  session.setTitle("Renamed");
  assert.equal(meta, 3);
});

test("lifecycle models draft → started as a discriminated union (P4)", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });

  // A freshly-constructed session is live (started), not a draft.
  const initial: SessionLifecycle = session.lifecycle;
  assert.equal(initial.phase, "started");
  assert.equal(session.pending, false);

  // Entering the draft phase records the deferred agent/base branch.
  session.beginDraft({ agent: "codex", baseBranch: "dev" });
  assert.equal(session.pending, true);
  assert.equal(session.pendingAgent, "codex");
  const draft: SessionLifecycle = session.lifecycle;
  if (draft.phase !== "draft") {
    assert.fail("expected a draft lifecycle");
  } else {
    assert.equal(draft.agent, "codex");
    assert.equal(draft.baseBranch, "dev");
  }

  // setPendingAgent only mutates a draft.
  session.setPendingAgent("pi");
  assert.equal(session.pendingAgent, "pi");

  // markStarted is the transition: pending clears, branch/worktree are set.
  session.markStarted({ branch: "feature-x", worktreePath: "/tmp/wt" });
  assert.equal(session.pending, false);
  assert.equal(session.pendingAgent, undefined);
  assert.equal(session.branch, "feature-x");
  assert.equal(session.worktreePath, "/tmp/wt");
  const afterStart: SessionLifecycle = session.lifecycle;
  assert.equal(afterStart.phase, "started");

  // setPendingAgent is a no-op once started.
  session.setPendingAgent("codex");
  assert.equal(session.pendingAgent, undefined);
});

test("pendingWorktreePath is unreadable on a started lifecycle (P4 type-level guard)", () => {
  const lc: SessionLifecycle = { phase: "started", branch: "b", worktreePath: "/tmp/wt" };
  if (lc.phase === "started") {
    // @ts-expect-error pendingWorktreePath exists only on the draft variant —
    // reading it on a started session is a compile error (the P4 invariant).
    void lc.pendingWorktreePath;
  }
  const draft: SessionLifecycle = { phase: "draft", agent: "pi", pendingWorktreePath: "/tmp/pending" };
  if (draft.phase === "draft") {
    assert.equal(draft.pendingWorktreePath, "/tmp/pending");
  }
});

test("with a store, events persist durably and seq survives a session restart", async () => {
  const { SqliteEventStore } = await import("./storage/sqlite_event_store.js");
  const store = new SqliteEventStore();

  const s1 = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter(), store });
  s1.adapter.emit("event", { ts: 1, kind: "user.message", payload: { text: "hi" } });
  s1.adapter.emit("event", { ts: 2, kind: "agent.message", payload: { text: "hello" } });

  // Store holds both events under the session's id.
  assert.deepEqual(store.read(s1.id).map((e) => e.payload.text), ["hi", "hello"]);
  // Session metadata is persisted (title/status/preview).
  assert.equal(store.loadSessions()[0].lastPreview, "hello");

  // "Restart": rebuild the session from the store, hydrate cache, continue seqs.
  const s2 = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter(), store, id: s1.id });
  s2.hydrate(store.read(s1.id));
  assert.equal(s2.events.length, 2);
  s2.adapter.emit("event", { ts: 3, kind: "user.message", payload: { text: "again" } });
  assert.deepEqual(store.read(s1.id).map((e) => e.seq), [1, 2, 3]);
  store.close();
});
