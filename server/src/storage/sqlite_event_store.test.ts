import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

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

test("migrates a legacy sessions schema in place, idempotently, keeping existing rows", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-"));
  const path = join(dir, "events.db");
  try {
    // Seed a pre-migration DB: sessions table WITHOUT resume_session_path,
    // branch, or worktree_path, plus one existing row.
    const legacy = new DatabaseSync(path);
    legacy.exec(`
      CREATE TABLE sessions (
        id             TEXT PRIMARY KEY,
        project_id     TEXT NOT NULL,
        agent          TEXT NOT NULL,
        title          TEXT NOT NULL,
        status         TEXT NOT NULL,
        policy         TEXT NOT NULL,
        created_at     INTEGER NOT NULL,
        last_activity_at INTEGER NOT NULL,
        last_preview   TEXT NOT NULL
      );
    `);
    legacy
      .prepare("INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
      .run("s-old", "p1", "pi", "legacy row", "idle", "ask-on-risky", 1000, 1000, "old");
    legacy.close();

    // Opening through the store migrates: row intact, new fields readable.
    const store = new SqliteEventStore(path);
    try {
      const loaded = store.loadSessions();
      assert.equal(loaded.length, 1);
      assert.equal(loaded[0].title, "legacy row");
      assert.equal(loaded[0].resumeSessionPath, undefined);
      assert.equal(loaded[0].branch, undefined);
      assert.equal(loaded[0].worktreePath, undefined);
      // The migrated columns are writable end-to-end.
      store.saveSession(meta("s-old", { title: "legacy row", branch: "b", worktreePath: "/wt" }));
    } finally {
      store.close();
    }

    // Reopening the already-migrated file is a no-op (idempotent migration).
    const reopened = new SqliteEventStore(path);
    try {
      const again = reopened.loadSessions();
      assert.equal(again.length, 1);
      assert.equal(again[0].branch, "b");
      assert.equal(again[0].worktreePath, "/wt");
    } finally {
      reopened.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
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

test("saveSession round-trips the agentSessionId resume handle (SPEC-29)", () => {
  const store = new SqliteEventStore();
  store.saveSession(meta("s1", { agentSessionId: "acp-abc-123" }));
  store.saveSession(meta("s2")); // no handle → undefined, not null
  const loaded = store.loadSessions();
  const s1 = loaded.find((s) => s.id === "s1")!;
  const s2 = loaded.find((s) => s.id === "s2")!;
  assert.equal(s1.agentSessionId, "acp-abc-123");
  assert.equal(s2.agentSessionId, undefined);
});

/**
 * The `archived` → `closed` rename must MIGRATE, not reset: a user who closed
 * (formerly archived) sessions before the upgrade must not find them all back in
 * the active list, with their agents respawned, after it.
 */
test("an existing DB's `archived` column migrates to `closed`, preserving values", () => {
  const dir = mkdtempSync(join(tmpdir(), "makit-store-migrate-"));
  const file = join(dir, "events.db");
  try {
    // Hand-build a pre-rename schema and seed one archived + one live session.
    const legacy = new DatabaseSync(file);
    legacy.exec(`
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        agent TEXT NOT NULL,
        title TEXT NOT NULL,
        status TEXT NOT NULL,
        policy TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        last_activity_at INTEGER NOT NULL,
        last_preview TEXT NOT NULL,
        resume_session_path TEXT,
        agent_session_id TEXT,
        branch TEXT,
        worktree_path TEXT,
        archived INTEGER NOT NULL DEFAULT 0
      );
    `);
    legacy.exec(
      `INSERT INTO sessions VALUES
         ('old-archived','p','pi','was archived','idle','ask',1,1,'',NULL,'acp-1',NULL,NULL,1),
         ('old-live','p','pi','was live','idle','ask',1,1,'',NULL,'acp-2',NULL,NULL,0)`,
    );
    legacy.close();

    const store = new SqliteEventStore(file);
    try {
      const loaded = store.loadSessions();
      assert.equal(loaded.find((s) => s.id === "old-archived")!.closed, true, "archived must survive as closed");
      assert.equal(loaded.find((s) => s.id === "old-live")!.closed, false);
      // And the flag is still writable through the new column name.
      store.saveSession({ ...loaded.find((s) => s.id === "old-live")!, closed: true });
      assert.equal(store.loadSessions().find((s) => s.id === "old-live")!.closed, true);
    } finally {
      store.close();
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saveSession round-trips the closed flag (SPEC-29)", () => {
  const store = new SqliteEventStore();
  store.saveSession(meta("s1", { closed: true }));
  store.saveSession(meta("s2"));
  const loaded = store.loadSessions();
  assert.equal(loaded.find((s) => s.id === "s1")!.closed, true);
  assert.equal(loaded.find((s) => s.id === "s2")!.closed, false);
});
