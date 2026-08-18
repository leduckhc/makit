/**
 * A session must not hold its whole history in memory.
 *
 * The server's RSS climbed 58 → 234 MB over 25 minutes as sessions were opened:
 * `hydrateFrom` read every persisted event of a session (one has 31,554) into a
 * cache that never shrank. The log on disk is the history; memory only needs the
 * recent tail, and anything older comes from the store on demand.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { Session, MEMORY_EVENT_CAP } from "./session.js";
import { SqliteEventStore } from "./storage/sqlite_event_store.js";
import type { AgentAdapter } from "./adapters/adapter.js";

function fakeAdapter(): AgentAdapter {
  const e = new EventEmitter() as unknown as AgentAdapter;
  (e as any).agent = "pi";
  (e as any).start = async () => {};
  (e as any).send = async () => {};
  (e as any).cancel = async () => {};
  (e as any).kill = async () => {};
  return e;
}

/** A store holding `n` persisted messages for one session id. */
function storeWith(id: string, n: number): SqliteEventStore {
  const store = new SqliteEventStore(":memory:");
  store.saveSession({
    id,
    projectId: "p",
    agent: "pi",
    title: "t",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1,
    lastActivityAt: 1,
    lastPreview: "",
  });
  for (let i = 1; i <= n; i++) {
    store.append(id, { ts: i, kind: "agent.message", payload: { msgId: `m${i}`, text: `t${i}` } });
  }
  return store;
}

function coldSession(store: SqliteEventStore, id: string): Session {
  return new Session({
    id,
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
    hydrateFrom: () => store.readTail(id, MEMORY_EVENT_CAP),
  });
}

test("a long session hydrates its tail, not its whole log", () => {
  const total = MEMORY_EVENT_CAP * 3;
  const store = storeWith("s1", total);
  const session = coldSession(store, "s1");

  assert.equal(session.events.length, MEMORY_EVENT_CAP);
  assert.equal(session.events.at(-1)?.seq, total, "the tail ends at the newest event");
});

test("eventsSince serves the tail from memory and older history from the store", () => {
  const total = MEMORY_EVENT_CAP * 3;
  const store = storeWith("s1", total);
  const session = coldSession(store, "s1");

  // Inside the tail: memory answers.
  const recent = session.eventsSince(total - 5);
  assert.deepEqual(recent.map((e) => e.seq), [total - 4, total - 3, total - 2, total - 1, total]);

  // Older than the tail: the store answers, and the whole history is there.
  const all = session.eventsSince(0);
  assert.equal(all.length, total);
  assert.equal(all[0].seq, 1);
  assert.equal(all.at(-1)?.seq, total);
});

test("a growing session trims its cache but still serves the full history", () => {
  const store = storeWith("s1", 0);
  const session = new Session({
    id: "s1",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
  });

  const total = MEMORY_EVENT_CAP * 3;
  for (let i = 1; i <= total; i++) {
    session.adapter.emit("event", {
      ts: i,
      kind: "agent.message",
      payload: { msgId: `m${i}`, text: `t${i}` },
    });
  }

  assert.ok(
    session.events.length <= MEMORY_EVENT_CAP * 2,
    `cache stayed bounded, got ${session.events.length}`,
  );
  assert.equal(session.eventsSince(0).length, total, "history is complete");
});

test("without a store the cache is the history, so nothing is trimmed", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });
  const total = MEMORY_EVENT_CAP * 3;
  for (let i = 1; i <= total; i++) {
    session.adapter.emit("event", {
      ts: i,
      kind: "agent.message",
      payload: { msgId: `m${i}`, text: `t${i}` },
    });
  }
  assert.equal(session.events.length, total);
  assert.equal(session.eventsSince(0).length, total);
});

// ARCHITECTURE §3.1: "a client that subscribes mid-turn still replays the partial
// text". A delta lives in memory and is never persisted, so once the cache is
// truncated the store-only path silently dropped the live answer.
test("a mid-turn replay from a truncated cache still carries the live deltas", () => {
  const store = storeWith("s1", 0);
  const session = new Session({
    id: "s1",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
  });

  // Push the cache past its trim point, so `truncated` is set.
  for (let i = 1; i <= MEMORY_EVENT_CAP * 3; i++) {
    session.adapter.emit("event", {
      ts: i,
      kind: "agent.message",
      payload: { msgId: `m${i}`, text: `t${i}` },
    });
  }
  // Now stream a turn that has not finished: deltas only, no final.
  for (const chunk of ["live ", "partial ", "text"]) {
    session.adapter.emit("event", {
      ts: 9000,
      kind: "agent.message.delta",
      payload: { msgId: "open", chunk },
    });
  }

  const replay = session.eventsSince(0);
  const deltas = replay.filter((e) => e.kind === "agent.message.delta");
  assert.equal(deltas.length, 3, "the partial answer is replayed, not lost");
  assert.deepEqual(
    replay.map((e) => e.seq),
    [...replay.map((e) => e.seq)].sort((a, b) => a - b),
    "the merged replay stays seq-ordered",
  );
  assert.equal(
    new Set(replay.map((e) => e.seq)).size,
    replay.length,
    "and carries no duplicate seq",
  );
});
