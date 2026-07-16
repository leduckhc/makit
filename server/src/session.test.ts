import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { Session } from "./session.js";
import type { AgentAdapter, AdapterEvent } from "./adapters/adapter.js";
import type { SessionEvent } from "./protocol.js";

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

test("lazy hydrateFrom is retained when the loader throws, and retried on next access", () => {
  const history: SessionEvent[] = [
    { seq: 1, sessionId: "s-lazy-retry", ts: 1, kind: "user.message", payload: { text: "old" } },
  ];
  let calls = 0;
  const session = new Session({
    id: "s-lazy-retry",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    hydrateFrom: () => {
      calls += 1;
      if (calls === 1) throw new Error("transient read failure");
      return history;
    },
  });

  // First access: loader throws → surfaced, and the loader is NOT consumed.
  assert.throws(() => session.events, /transient read failure/);
  // Retry: loader runs again and history is restored (not permanently lost).
  assert.equal(session.events.length, 1);
  assert.equal(session.events[0].payload.text, "old");
  assert.equal(calls, 2, "loader retried exactly once after the failure");
});
