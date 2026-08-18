/**
 * The write path must not pay for what it does not need.
 *
 * Streaming a turn used to cost, per token: one `db.prepare` for the event
 * insert, one full 17-column `sessions` upsert (with its own `db.prepare`), and
 * an fsync for each — `PRAGMA journal_mode = WAL` was set but `synchronous` was
 * left at the default FULL. Across the 1.7 M events of one profile log that is
 * ~3.4 M compiles and ~3.4 M commits for data nothing read.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { SqliteEventStore } from "./storage/sqlite_event_store.js";
import { Session } from "./session.js";
import type { AgentAdapter } from "./adapters/adapter.js";
import type { SessionMeta } from "./storage/event_store.js";

function fakeAdapter(): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "pi";
  (e as any).start = async () => {};
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  return e;
}

test("WAL runs with synchronous=NORMAL, so a commit does not fsync", () => {
  const store = new SqliteEventStore(":memory:");
  assert.equal(store.pragma("journal_mode"), "memory", "an in-memory db has no WAL");
  // The pragma is set regardless of the journal mode the file ends up in.
  assert.equal(Number(store.pragma("synchronous")), 1, "1 = NORMAL");
  store.close();
});

test("statements are compiled once, not once per row", () => {
  const store = new SqliteEventStore(":memory:");
  store.saveSession(meta("s1"));
  for (let i = 0; i < 200; i++) {
    store.append("s1", { ts: i, kind: "agent.message", payload: { text: `m${i}` } });
  }
  assert.ok(
    store.compiledStatementCount <= 6,
    `one statement per SQL text, got ${store.compiledStatementCount}`,
  );
  assert.equal(store.read("s1", 0).length, 200, "and the rows are all there");
  store.close();
});

test("a streamed token does not rewrite the session row", () => {
  const writes: SessionMeta[] = [];
  const store = new SqliteEventStore(":memory:");
  const counting: SqliteEventStore = Object.create(store);
  counting.saveSession = (m: SessionMeta) => {
    writes.push({ ...m });
    store.saveSession(m);
  };

  const session = new Session({
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store: counting,
  });
  const atStart = writes.length; // the constructor persists the new session
  session.adapter.emit("event", {
    ts: 1,
    kind: "session.status",
    payload: { status: "running" },
  });
  const afterStatus = writes.length;
  assert.ok(afterStatus > atStart, "a status change IS meta");

  for (let i = 0; i < 50; i++) {
    session.adapter.emit("event", {
      ts: 2 + i,
      kind: "agent.message.delta",
      payload: { msgId: "m1", chunk: "x" },
    });
  }
  assert.equal(writes.length, afterStatus, "50 tokens, no session-row write");

  // The turn's real change still lands: the final and the closing status.
  session.adapter.emit("event", {
    ts: 100,
    kind: "agent.message",
    payload: { msgId: "m1", text: "x".repeat(50) },
  });
  assert.ok(writes.length > afterStatus, "the preview is meta");
  assert.equal(writes.at(-1)?.lastPreview, "x".repeat(50));
  store.close();
});

test("a skipped write never loses the last activity time", () => {
  const store = new SqliteEventStore(":memory:");
  const session = new Session({ id: "s1", projectId: "p", agent: "pi", adapter: fakeAdapter(), store });
  session.adapter.emit("event", { ts: 10, kind: "session.status", payload: { status: "running" } });
  session.adapter.emit("event", {
    ts: 20,
    kind: "agent.message.delta",
    payload: { msgId: "m1", chunk: "x" },
  });
  session.adapter.emit("event", { ts: 30, kind: "session.status", payload: { status: "idle" } });

  const persisted = store.loadSessions().find((m) => m.id === "s1");
  assert.equal(persisted?.lastActivityAt, 30, "the next real event carries it");
  store.close();
});

function meta(id: string): SessionMeta {
  return {
    id,
    projectId: "p",
    agent: "pi",
    title: "t",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 1,
    lastPreview: "",
  };
}
