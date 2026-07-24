import { test } from "node:test";
import assert from "node:assert/strict";

import { SqliteEventStore } from "./sqlite_event_store.js";
import type { SessionMeta } from "./event_store.js";

function meta(id: string, over: Partial<SessionMeta> = {}): SessionMeta {
  return {
    id,
    projectId: "p1",
    agent: "pi",
    title: "new session",
    status: "idle",
    policy: "ask-on-risky",
    createdAt: 1000,
    lastActivityAt: 1000,
    lastPreview: "",
    ...over,
  };
}

test("append assigns monotonic per-session seqs starting at 1", () => {
  const store = new SqliteEventStore();
  const a = store.append("s1", { ts: 1, kind: "user.message", payload: { text: "hi" } });
  const b = store.append("s1", { ts: 2, kind: "agent.message", payload: { text: "yo" } });
  // A different session has its own seq space.
  const c = store.append("s2", { ts: 3, kind: "user.message", payload: { text: "other" } });

  assert.deepEqual([a.seq, b.seq, c.seq], [1, 2, 1]);
  assert.equal(a.sessionId, "s1");
  assert.equal(c.sessionId, "s2");
  store.close();
});

test("append after deleteSession restarts the session's seq space at 1", () => {
  const store = new SqliteEventStore();
  store.append("s1", { ts: 1, kind: "user.message", payload: { text: "one" } });
  store.append("s1", { ts: 2, kind: "agent.message", payload: { text: "two" } });
  store.deleteSession("s1");

  // A cached seq counter must not survive the delete.
  const fresh = store.append("s1", { ts: 3, kind: "user.message", payload: { text: "anew" } });
  assert.equal(fresh.seq, 1);
  store.close();
});

test("read returns events with seq > fromSeq, ascending; fromSeq=0 returns all", () => {
  const store = new SqliteEventStore();
  store.append("s1", { ts: 1, kind: "user.message", payload: { text: "one" } });
  store.append("s1", { ts: 2, kind: "agent.message", payload: { text: "two" } });
  store.append("s1", { ts: 3, kind: "agent.message", payload: { text: "three" } });

  assert.deepEqual(store.read("s1").map((e) => e.seq), [1, 2, 3]);
  assert.deepEqual(store.read("s1", 1).map((e) => e.seq), [2, 3]);
  assert.deepEqual(store.read("s1", 3), []);
  // Payload round-trips through JSON intact.
  assert.equal(store.read("s1", 1)[0].payload.text, "two");
  store.close();
});

test("state survives 'restart': reopening the same file replays events + seq", () => {
  const path = `/tmp/makit-test-${process.pid}-${Date.now()}.db`;
  const first = new SqliteEventStore(path);
  first.saveSession(meta("s1", { title: "resume me", lastActivityAt: 5 }));
  first.append("s1", { ts: 1, kind: "user.message", payload: { text: "before restart" } });
  first.close();

  const second = new SqliteEventStore(path);
  const sessions = second.loadSessions();
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].title, "resume me");

  // seq continues after the persisted max, not from 1 again.
  const next = second.append("s1", { ts: 2, kind: "agent.message", payload: { text: "after" } });
  assert.equal(next.seq, 2);
  assert.deepEqual(second.read("s1").map((e) => e.payload.text), ["before restart", "after"]);
  second.close();
});

test("saveSession upserts by id; loadSessions orders by lastActivityAt desc", () => {
  const store = new SqliteEventStore();
  store.saveSession(meta("s1", { lastActivityAt: 10 }));
  store.saveSession(meta("s2", { lastActivityAt: 30 }));
  store.saveSession(meta("s3", { lastActivityAt: 20 }));
  // Upsert s1: same row, new title + activity.
  store.saveSession(meta("s1", { title: "renamed", lastActivityAt: 40 }));

  const ordered = store.loadSessions();
  assert.deepEqual(ordered.map((s) => s.id), ["s1", "s2", "s3"]);
  assert.equal(ordered.find((s) => s.id === "s1")!.title, "renamed");
  store.close();
});

test("saveSession round-trips branch + worktreePath (absent stays undefined)", () => {
  const store = new SqliteEventStore();
  store.saveSession(meta("s1", { branch: "feature-x", worktreePath: "/tmp/wt" }));
  store.saveSession(meta("s2"));

  const byId = new Map(store.loadSessions().map((s) => [s.id, s]));
  assert.equal(byId.get("s1")!.branch, "feature-x");
  assert.equal(byId.get("s1")!.worktreePath, "/tmp/wt");
  assert.equal(byId.get("s2")!.branch, undefined);
  assert.equal(byId.get("s2")!.worktreePath, undefined);
  store.close();
});

test("deleteSession removes the session and its events", () => {
  const store = new SqliteEventStore();
  store.saveSession(meta("s1"));
  store.append("s1", { ts: 1, kind: "user.message", payload: {} });
  store.deleteSession("s1");
  assert.deepEqual(store.loadSessions(), []);
  assert.deepEqual(store.read("s1"), []);
  store.close();
});
