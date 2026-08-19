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

// The cap must not eat the turn that is still streaming. A delta is never
// persisted, so a delta the cache drops is gone for good: trimming mid-stream
// truncated the answer a mid-turn subscriber replays.
test("a long stream is not trimmed away while it is still open", () => {
  const store = storeWith("s1", 0);
  const session = new Session({
    id: "s1",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
  });

  session.adapter.emit("event", { ts: 1, kind: "session.status", payload: { status: "running" } });
  const chunks = MEMORY_EVENT_CAP * 3;
  for (let i = 1; i <= chunks; i++) {
    session.adapter.emit("event", {
      ts: i,
      kind: "agent.message.delta",
      payload: { msgId: "m1", chunk: `c${i} ` },
    });
  }

  const replay = session.eventsSince(0);
  assert.equal(
    replay.filter((e) => e.kind === "agent.message.delta").length,
    chunks,
    "every chunk of the open turn is still replayable",
  );

  // Once the turn ends, the aggregate carries the text and the cache is free to
  // shrink again — that is what the cap is for.
  session.adapter.emit("event", { ts: 9999, kind: "session.status", payload: { status: "idle" } });
  assert.ok(
    session.events.length <= MEMORY_EVENT_CAP * 2,
    `cache is bounded again after the close, got ${session.events.length}`,
  );
  const text = store
    .read("s1", 0)
    .find((e) => e.kind === "agent.message")?.payload.text as string | undefined;
  assert.ok(text?.startsWith("c1 "), "and the aggregate kept the text from the first chunk on");
});

// The field incident: a session streamed 6,147 work events over an hour without
// a turn-end status. `trimCache` only ran once the digest was empty, and the
// digest stayed open for the whole turn, so the cache never shrank. A finished
// stream's deltas are redundant — its persisted final carries the same text — so
// they must leave memory the moment the final lands, not at a turn end that may
// never come.
test("a never-idle session evicts finished streams' deltas and stays bounded", () => {
  const store = storeWith("s1", 0);
  const session = new Session({
    id: "s1",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
  });

  session.adapter.emit("event", { ts: 0, kind: "session.status", payload: { status: "running" } });
  // Many COMPLETE message streams, but the turn never ends (no idle/exited).
  const messages = MEMORY_EVENT_CAP * 3;
  for (let m = 1; m <= messages; m++) {
    const msgId = `m${m}`;
    for (const chunk of ["a", "b", "c"]) {
      session.adapter.emit("event", { ts: m, kind: "agent.message.delta", payload: { msgId, chunk } });
    }
    session.adapter.emit("event", { ts: m, kind: "agent.message", payload: { msgId, text: "abc" } });
  }

  // No turn-end status ever arrived: the agent is still working.
  assert.equal(session.status, "running");
  assert.ok(
    session.events.length <= MEMORY_EVENT_CAP * 2,
    `cache stayed bounded mid-turn, got ${session.events.length}`,
  );
  // The whole answer is still readable from the store.
  assert.equal(
    session.eventsSince(0).filter((e) => e.kind === "agent.message").length,
    messages,
    "every finished message is still history",
  );
});

// The invariant that guards the bound above: evicting FINISHED streams must
// never touch the OPEN one. A mid-turn subscriber replays the store's finals
// plus the un-persisted deltas of the answer still being typed, complete and in
// order.
//
// The open stream is opened FIRST here, on purpose. That keeps the digest
// non-empty for every event that follows, which is the shape that used to switch
// the tail cap off completely and let the cache grow for the whole turn.
test("a mid-turn subscriber still replays the open answer after evictions", () => {
  const store = storeWith("s1", 0);
  const session = new Session({
    id: "s1",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
  });

  // The answer being typed opens first and never finals, so the digest stays
  // non-empty from here on.
  for (const chunk of ["Hello ", "world", "!"]) {
    session.adapter.emit("event", { ts: 9000, kind: "agent.message.delta", payload: { msgId: "open", chunk } });
  }

  // Enough finished streams to force the cache to trim.
  for (let m = 1; m <= MEMORY_EVENT_CAP * 3; m++) {
    session.adapter.emit("event", { ts: m, kind: "agent.message.delta", payload: { msgId: `m${m}`, chunk: "x" } });
    session.adapter.emit("event", { ts: m, kind: "agent.message", payload: { msgId: `m${m}`, text: `full${m}` } });
  }

  // An open stream may hold its own deltas, and nothing else.
  assert.ok(
    session.events.length <= MEMORY_EVENT_CAP * 2,
    `cache stayed bounded around an open stream, got ${session.events.length}`,
  );

  const replay = session.eventsSince(0);
  // The open answer's deltas live only in memory, so they must all survive.
  assert.deepEqual(
    replay
      .filter((e) => e.kind === "agent.message.delta" && e.payload.msgId === "open")
      .map((e) => e.payload.chunk),
    ["Hello ", "world", "!"],
    "the open answer is replayed whole, not truncated",
  );
  // And an early finished message is still replayable from the store.
  assert.ok(
    replay.some((e) => e.kind === "agent.message" && e.payload.text === "full1"),
    "finished history is still there",
  );
  const seqs = replay.map((e) => e.seq);
  assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b), "the replay stays seq-ordered");
  assert.equal(new Set(seqs).size, seqs.length, "and carries no duplicate seq");
});

// Eviction keeps an open stream's deltas even when it drops NEWER events, so the
// cache is no longer a contiguous tail. "Is the cache complete for this caller?"
// therefore cannot be answered from the oldest cached seq: that seq belongs to
// the open answer, and reading it as the start of an unbroken tail would serve a
// subscriber a cache with a hole in it and skip the store entirely.
test("a cursor above the open stream still reloads the evicted middle", () => {
  const store = storeWith("s1", 0);
  const session = new Session({
    id: "s1",
    projectId: "p",
    agent: "pi",
    adapter: fakeAdapter(),
    store,
  });

  // Seqs 1..3: the open answer, kept in memory for the whole turn.
  for (const chunk of ["Hello ", "world", "!"]) {
    session.adapter.emit("event", { ts: 1, kind: "agent.message.delta", payload: { msgId: "open", chunk } });
  }
  // Seq 4 onwards: finished streams, evicted once the cap bites.
  for (let m = 1; m <= MEMORY_EVENT_CAP * 3; m++) {
    session.adapter.emit("event", { ts: m, kind: "agent.message.delta", payload: { msgId: `m${m}`, chunk: "x" } });
    session.adapter.emit("event", { ts: m, kind: "agent.message", payload: { msgId: `m${m}`, text: `full${m}` } });
  }

  // A cursor just past the open deltas: every finished message must still arrive.
  const replay = session.eventsSince(3);
  const finals = replay.filter((e) => e.kind === "agent.message").length;
  assert.equal(finals, MEMORY_EVENT_CAP * 3, "the evicted middle came back from the store");
  const seqs = replay.map((e) => e.seq);
  assert.deepEqual(seqs, [...seqs].sort((a, b) => a - b), "still seq-ordered");
  assert.equal(new Set(seqs).size, seqs.length, "and free of duplicates");
});
