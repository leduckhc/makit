/**
 * SqliteEventStore — {@link EventStore} backed by Node's built-in `node:sqlite`.
 *
 * Uses a single database file (default `:memory:` for tests). Synchronous by
 * design so `append` can return the assigned `seq` inline, preserving the
 * write-before-fanout invariant. No native dependency: `node:sqlite` ships with
 * Node ≥ 22.5 and is stable on the project's Node floor.
 */

import { DatabaseSync } from "node:sqlite";
import type { SessionEvent } from "../protocol.js";
import type { EventStore, NewEvent, SessionMeta } from "./event_store.js";

export class SqliteEventStore implements EventStore {
  private readonly db: DatabaseSync;

  constructor(path = ":memory:") {
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA journal_mode = WAL;");
    this.db.exec("PRAGMA foreign_keys = ON;");
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        id             TEXT PRIMARY KEY,
        project_id     TEXT NOT NULL,
        agent          TEXT NOT NULL,
        title          TEXT NOT NULL,
        status         TEXT NOT NULL,
        policy         TEXT NOT NULL,
        created_at     INTEGER NOT NULL,
        last_activity_at INTEGER NOT NULL,
        last_preview   TEXT NOT NULL,
        resume_session_path TEXT
      );
      CREATE TABLE IF NOT EXISTS events (
        session_id TEXT NOT NULL,
        seq        INTEGER NOT NULL,
        ts         INTEGER NOT NULL,
        kind       TEXT NOT NULL,
        payload    TEXT NOT NULL,
        PRIMARY KEY (session_id, seq)
      );
      CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, seq);
    `);
    // Back-compat: add the nullable resume path to pre-existing DBs whose
    // sessions table predates this column.
    const cols = this.db.prepare("PRAGMA table_info(sessions)").all() as Array<{ name: string }>;
    if (!cols.some((c) => c.name === "resume_session_path")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN resume_session_path TEXT");
    }
  }

  append(sessionId: string, e: NewEvent): SessionEvent {
    const row = this.db
      .prepare("SELECT COALESCE(MAX(seq), 0) AS maxSeq FROM events WHERE session_id = ?")
      .get(sessionId) as { maxSeq: number };
    const seq = Number(row.maxSeq) + 1;
    this.db
      .prepare("INSERT INTO events (session_id, seq, ts, kind, payload) VALUES (?, ?, ?, ?, ?)")
      .run(sessionId, seq, e.ts, e.kind, JSON.stringify(e.payload ?? {}));
    return { seq, sessionId, ts: e.ts, kind: e.kind, payload: e.payload };
  }

  read(sessionId: string, fromSeq = 0): SessionEvent[] {
    const rows = this.db
      .prepare(
        "SELECT seq, ts, kind, payload FROM events WHERE session_id = ? AND seq > ? ORDER BY seq ASC",
      )
      .all(sessionId, fromSeq) as Array<{ seq: number; ts: number; kind: string; payload: string }>;
    return rows.map((r) => ({
      seq: Number(r.seq),
      sessionId,
      ts: Number(r.ts),
      kind: r.kind as SessionEvent["kind"],
      payload: JSON.parse(r.payload) as Record<string, unknown>,
    }));
  }

  saveSession(m: SessionMeta): void {
    this.db
      .prepare(
        `INSERT INTO sessions
           (id, project_id, agent, title, status, policy, created_at, last_activity_at, last_preview, resume_session_path)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           project_id = excluded.project_id,
           agent = excluded.agent,
           title = excluded.title,
           status = excluded.status,
           policy = excluded.policy,
           last_activity_at = excluded.last_activity_at,
           last_preview = excluded.last_preview,
           resume_session_path = excluded.resume_session_path`,
      )
      .run(
        m.id,
        m.projectId,
        m.agent,
        m.title,
        m.status,
        m.policy,
        m.createdAt,
        m.lastActivityAt,
        m.lastPreview,
        m.resumeSessionPath ?? null,
      );
  }

  loadSessions(): SessionMeta[] {
    const rows = this.db
      .prepare(
        `SELECT id, project_id, agent, title, status, policy, created_at, last_activity_at, last_preview, resume_session_path
         FROM sessions ORDER BY last_activity_at DESC`,
      )
      .all() as Array<Record<string, unknown>>;
    return rows.map((r) => ({
      id: r.id as string,
      projectId: r.project_id as string,
      agent: r.agent as string,
      title: r.title as string,
      status: r.status as SessionMeta["status"],
      policy: r.policy as SessionMeta["policy"],
      createdAt: Number(r.created_at),
      lastActivityAt: Number(r.last_activity_at),
      lastPreview: r.last_preview as string,
      resumeSessionPath: (r.resume_session_path as string | null) ?? undefined,
    }));
  }

  deleteSession(id: string): void {
    this.db.prepare("DELETE FROM events WHERE session_id = ?").run(id);
    this.db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
  }

  close(): void {
    this.db.close();
  }
}
