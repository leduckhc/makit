/**
 * The existing log must shrink, by the same rule the live path now follows.
 *
 * A profile database held 1,795,475 rows in 730 MB, of which 93% were streaming
 * deltas that a final already superseded. `stream_digest.ts` stops writing new
 * ones; this compaction removes the ones already written, and it uses the SAME
 * digest, so the two can never disagree.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import { SqliteEventStore } from "./sqlite_event_store.js";
import { compactSessionLog, compactAll } from "./compact.js";

function seed(store: SqliteEventStore, id: string): void {
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
}

test("a streamed turn collapses to its finals", () => {
  const store = new SqliteEventStore(":memory:");
  seed(store, "s1");
  const rows: Array<[string, Record<string, unknown>]> = [
    ["user.message", { text: "hi" }],
    ["session.status", { status: "running" }],
    ["agent.thinking.delta", { thinkId: "t1", chunk: "hm" }],
    ["agent.thinking.delta", { thinkId: "t1", chunk: "mm" }],
    ["agent.thinking", { thinkId: "t1", text: "hmmm" }],
    ["agent.message.delta", { msgId: "m1", chunk: "Hel" }],
    ["agent.message.delta", { msgId: "m1", chunk: "lo" }],
    ["agent.message", { msgId: "m1", text: "Hello" }],
    ["session.status", { status: "idle" }],
  ];
  for (const [kind, payload] of rows) {
    store.append("s1", { ts: 1, kind: kind as never, payload });
  }

  const result = compactSessionLog(store, "s1");

  assert.equal(result.removed, 4, "four delta rows go");
  assert.equal(result.aggregated, 0, "both streams had a final");
  assert.deepEqual(
    store.read("s1", 0).map((e) => e.kind),
    [
      "user.message",
      "session.status",
      "agent.thinking",
      "agent.message",
      "session.status",
    ],
  );
  // Seqs keep their order and their gaps: a client's cursor still means the
  // same thing after compaction.
  assert.deepEqual(
    store.read("s1", 0).map((e) => e.seq),
    [1, 2, 5, 8, 9],
  );
});

test("a stream with no final is kept as one aggregated row", () => {
  const store = new SqliteEventStore(":memory:");
  seed(store, "s1");
  store.append("s1", { ts: 1, kind: "session.status", payload: { status: "running" } });
  store.append("s1", { ts: 2, kind: "agent.message.delta", payload: { msgId: "m1", chunk: "half " } });
  store.append("s1", { ts: 3, kind: "agent.message.delta", payload: { msgId: "m1", chunk: "said" } });
  store.append("s1", { ts: 4, kind: "session.status", payload: { status: "idle" } });

  const result = compactSessionLog(store, "s1");

  assert.equal(result.aggregated, 1);
  const kept = store.read("s1", 0);
  assert.deepEqual(kept.map((e) => e.kind), [
    "session.status",
    "agent.message",
    "session.status",
  ]);
  assert.equal(kept[1].payload.text, "half said");
  assert.equal(kept[1].seq, 2, "the aggregate takes the first delta's seq");
});

test("tool output moves into an end event that lacks it", () => {
  const store = new SqliteEventStore(":memory:");
  seed(store, "s1");
  store.append("s1", { ts: 1, kind: "session.status", payload: { status: "running" } });
  store.append("s1", { ts: 2, kind: "tool.call.start", payload: { callId: "c1", name: "bash" } });
  store.append("s1", { ts: 3, kind: "tool.call.delta", payload: { callId: "c1", chunk: "a\n" } });
  store.append("s1", { ts: 4, kind: "tool.call.delta", payload: { callId: "c1", chunk: "b\n" } });
  store.append("s1", { ts: 5, kind: "tool.call.end", payload: { callId: "c1", exitCode: 0 } });
  store.append("s1", { ts: 6, kind: "session.status", payload: { status: "idle" } });

  compactSessionLog(store, "s1");

  const end = store.read("s1", 0).find((e) => e.kind === "tool.call.end");
  assert.equal(end?.payload.output, "a\nb\n", "no tool output is lost");
  assert.equal(store.read("s1", 0).some((e) => e.kind === "tool.call.delta"), false);
});

test("compaction is idempotent", () => {
  const store = new SqliteEventStore(":memory:");
  seed(store, "s1");
  store.append("s1", { ts: 1, kind: "session.status", payload: { status: "running" } });
  store.append("s1", { ts: 2, kind: "agent.message.delta", payload: { msgId: "m1", chunk: "x" } });
  store.append("s1", { ts: 3, kind: "agent.message", payload: { msgId: "m1", text: "x" } });
  store.append("s1", { ts: 4, kind: "session.status", payload: { status: "idle" } });

  compactSessionLog(store, "s1");
  const once = store.read("s1", 0);
  const second = compactSessionLog(store, "s1");

  assert.equal(second.removed, 0);
  assert.equal(second.aggregated, 0);
  assert.deepEqual(store.read("s1", 0), once);
});

test("an unfinished turn is left alone until it ends", () => {
  const store = new SqliteEventStore(":memory:");
  seed(store, "s1");
  store.append("s1", { ts: 1, kind: "session.status", payload: { status: "running" } });
  store.append("s1", { ts: 2, kind: "agent.message.delta", payload: { msgId: "m1", chunk: "still " } });
  store.append("s1", { ts: 3, kind: "agent.message.delta", payload: { msgId: "m1", chunk: "going" } });

  const result = compactSessionLog(store, "s1", { keepOpenTurn: true });

  assert.equal(result.removed, 0, "a live turn keeps its partial text");
  assert.equal(store.read("s1", 0).length, 3);
});

test("compactAll reports every session it touched", () => {
  const store = new SqliteEventStore(":memory:");
  for (const id of ["s1", "s2"]) {
    seed(store, id);
    store.append(id, { ts: 1, kind: "session.status", payload: { status: "running" } });
    store.append(id, { ts: 2, kind: "agent.message.delta", payload: { msgId: "m1", chunk: "a" } });
    store.append(id, { ts: 3, kind: "agent.message", payload: { msgId: "m1", text: "a" } });
    store.append(id, { ts: 4, kind: "session.status", payload: { status: "idle" } });
  }

  const totals = compactAll(store);

  assert.equal(totals.sessions, 2);
  assert.equal(totals.removed, 2);
  assert.equal(totals.aggregated, 0);
});
