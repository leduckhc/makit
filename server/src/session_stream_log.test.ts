/**
 * The log must not keep one row per streamed token.
 *
 * A profile database held 1,795,475 events in 730 MB. 93% of them were
 * streaming deltas — 1,192,853 `agent.thinking.delta` alone — which the final
 * `agent.message` / `agent.thinking` / `tool.call.end` already supersede. Every
 * one of those rows also cost a synchronous SQLite commit while the agent
 * streamed, and every one stayed in memory for the life of the server.
 *
 * The rule these tests pin: a delta is LIVE data, not history. It is emitted to
 * clients, and it takes a seq, but it reaches the log only as an aggregate — and
 * only when no final carries the same text.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";

import { Session } from "./session.js";
import { SqliteEventStore } from "./storage/sqlite_event_store.js";
import type { AgentAdapter } from "./adapters/adapter.js";
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

/** A session on a fresh in-memory store, plus everything it emitted. */
function withSession() {
  const store = new SqliteEventStore(":memory:");
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter(), store });
  const emitted: SessionEvent[] = [];
  session.on("event", (ev: SessionEvent) => emitted.push(ev));
  const feed = (kind: string, payload: Record<string, unknown>) =>
    session.adapter.emit("event", { ts: Date.now(), kind, payload });
  const persisted = () => store.read(session.id, 0);
  return { store, session, emitted, feed, persisted };
}

test("a streamed message reaches the log once, as its final", () => {
  const { session, emitted, feed, persisted } = withSession();

  feed("user.message", { text: "hi" });
  feed("session.status", { status: "running" });
  for (const chunk of ["Hel", "lo ", "there"]) {
    feed("agent.message.delta", { msgId: "m1", chunk });
  }
  feed("agent.message", { msgId: "m1", text: "Hello there" });
  feed("session.status", { status: "idle" });

  // Live clients still see every token.
  assert.deepEqual(
    emitted.filter((e) => e.kind === "agent.message.delta").map((e) => e.payload.chunk),
    ["Hel", "lo ", "there"],
  );

  // The log holds the final and no deltas.
  assert.deepEqual(
    persisted().map((e) => e.kind),
    ["user.message", "session.status", "agent.message", "session.status"],
  );

  // Memory agrees with the log once the turn closes.
  assert.deepEqual(
    session.events.map((e) => e.kind),
    ["user.message", "session.status", "agent.message", "session.status"],
  );
});

test("seqs stay monotonic even though deltas are not written", () => {
  const { emitted, feed } = withSession();

  feed("session.status", { status: "running" });
  feed("agent.message.delta", { msgId: "m1", chunk: "a" });
  feed("agent.message.delta", { msgId: "m1", chunk: "b" });
  feed("agent.message", { msgId: "m1", text: "ab" });
  feed("session.status", { status: "idle" });

  const seqs = emitted.map((e) => e.seq);
  assert.deepEqual(seqs, [1, 2, 3, 4, 5], "a delta consumes its seq like any event");
  assert.deepEqual(new Set(seqs).size, seqs.length, "no seq is reused");
});

test("a stream with no final is aggregated into one event at the first delta's seq", () => {
  const { session, feed, persisted } = withSession();

  feed("session.status", { status: "running" });
  feed("agent.thinking.delta", { thinkId: "t1", chunk: "step one " });
  feed("agent.thinking.delta", { thinkId: "t1", chunk: "step two" });
  feed("session.status", { status: "idle" });

  const rows = persisted();
  assert.deepEqual(rows.map((e) => e.kind), [
    "session.status",
    "agent.thinking",
    "session.status",
  ]);
  const thinking = rows[1];
  assert.equal(thinking.payload.text, "step one step two");
  assert.equal(thinking.payload.thinkId, "t1");
  assert.equal(thinking.seq, 2, "it takes the seq of the first delta it replaces");

  assert.deepEqual(
    session.events.map((e) => e.kind),
    ["session.status", "agent.thinking", "session.status"],
  );
});

test("tool output survives: the end event carries the chunks it had none of", () => {
  const { feed, persisted, emitted } = withSession();

  feed("session.status", { status: "running" });
  feed("tool.call.start", { callId: "c1", name: "bash", args: { cmd: "ls" } });
  feed("tool.call.delta", { callId: "c1", chunk: "a.txt\n" });
  feed("tool.call.delta", { callId: "c1", chunk: "b.txt\n" });
  feed("tool.call.end", { callId: "c1", exitCode: 0 });
  feed("session.status", { status: "idle" });

  const end = persisted().find((e) => e.kind === "tool.call.end");
  assert.ok(end, "the end event is history");
  assert.equal(end.payload.output, "a.txt\nb.txt\n");
  // The live end event carries it too, so both paths render the same card.
  const liveEnd = emitted.find((e) => e.kind === "tool.call.end");
  assert.equal(liveEnd?.payload.output, "a.txt\nb.txt\n");
  assert.equal(
    persisted().some((e) => e.kind === "tool.call.delta"),
    false,
  );
});

test("an end event that reports its own output keeps it", () => {
  const { feed, persisted } = withSession();

  feed("session.status", { status: "running" });
  feed("tool.call.start", { callId: "c1", name: "bash" });
  feed("tool.call.delta", { callId: "c1", chunk: "noise" });
  feed("tool.call.end", { callId: "c1", exitCode: 0, output: "the whole truth" });
  feed("session.status", { status: "idle" });

  const end = persisted().find((e) => e.kind === "tool.call.end");
  assert.equal(end?.payload.output, "the whole truth");
});

test("a tool call with no end keeps its output as one aggregated delta", () => {
  const { feed, persisted } = withSession();

  feed("session.status", { status: "running" });
  feed("tool.call.start", { callId: "c1", name: "bash" });
  feed("tool.call.delta", { callId: "c1", chunk: "one " });
  feed("tool.call.delta", { callId: "c1", chunk: "two" });
  feed("session.status", { status: "idle" });

  const deltas = persisted().filter((e) => e.kind === "tool.call.delta");
  assert.equal(deltas.length, 1);
  assert.equal(deltas[0].payload.chunk, "one two");
});

test("a mid-turn read still sees the deltas: they leave memory only at the close", () => {
  const { session, feed } = withSession();

  feed("session.status", { status: "running" });
  feed("agent.message.delta", { msgId: "m1", chunk: "par" });
  feed("agent.message.delta", { msgId: "m1", chunk: "tial" });

  // A phone that subscribes mid-turn must see the partial answer.
  assert.deepEqual(
    session.events.filter((e) => e.kind === "agent.message.delta").map((e) => e.payload.chunk),
    ["par", "tial"],
  );
});

test("a session with no store keeps working, deltas included", () => {
  const session = new Session({ projectId: "p", agent: "pi", adapter: fakeAdapter() });
  session.adapter.emit("event", {
    ts: 1,
    kind: "agent.message.delta",
    payload: { msgId: "m1", chunk: "x" },
  });
  session.adapter.emit("event", { ts: 2, kind: "session.status", payload: { status: "idle" } });
  assert.deepEqual(session.events.map((e) => e.kind), ["agent.message", "session.status"]);
});
