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
  /** Next seq per session — avoids a MAX(seq) query on every append. */
  private readonly nextSeq = new Map<string, number>();

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
        resume_session_path TEXT,
        agent_session_id TEXT,
        branch         TEXT,
        worktree_path  TEXT,
        closed       INTEGER NOT NULL DEFAULT 0
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
    // Back-compat: add nullable columns to pre-existing DBs whose sessions
    // table predates them.
    const cols = this.db.prepare("PRAGMA table_info(sessions)").all() as Array<{ name: string }>;
    if (!cols.some((c) => c.name === "resume_session_path")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN resume_session_path TEXT");
    }
    if (!cols.some((c) => c.name === "agent_session_id")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN agent_session_id TEXT");
    }
    if (!cols.some((c) => c.name === "branch")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN branch TEXT");
    }
    if (!cols.some((c) => c.name === "worktree_path")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN worktree_path TEXT");
    }
    // SPEC-session-lifecycle-resume-list-delete close/reopen: the flag was called `archived` before sessions grew a
    // real close (release the agent, keep the session). RENAME rather than add,
    // so sessions a user had already closed stay closed across the upgrade —
    // adding a fresh column would silently return every one of them to the
    // active list and respawn its agent on the next subscribe.
    if (cols.some((c) => c.name === "archived") && !cols.some((c) => c.name === "closed")) {
      this.db.exec("ALTER TABLE sessions RENAME COLUMN archived TO closed");
    } else if (!cols.some((c) => c.name === "closed")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN closed INTEGER NOT NULL DEFAULT 0");
    }
    // SPEC-cli-as-client lineage (D10): nullable, back-filled to NULL on existing rows so a
    // session written before SPEC-cli-as-client rehydrates with all three undefined.
    if (!cols.some((c) => c.name === "parent_id")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN parent_id TEXT");
    }
    if (!cols.some((c) => c.name === "handoff_reason")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN handoff_reason TEXT");
    }
    if (!cols.some((c) => c.name === "origin")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN origin TEXT");
    }
  }

  append(sessionId: string, e: NewEvent): SessionEvent {
    let seq = this.nextSeq.get(sessionId);
    if (seq === undefined) {
      const row = this.db
        .prepare("SELECT COALESCE(MAX(seq), 0) AS maxSeq FROM events WHERE session_id = ?")
        .get(sessionId) as { maxSeq: number };
      seq = Number(row.maxSeq) + 1;
    }
    this.db
      .prepare("INSERT INTO events (session_id, seq, ts, kind, payload) VALUES (?, ?, ?, ?, ?)")
      .run(sessionId, seq, e.ts, e.kind, JSON.stringify(e.payload ?? {}));
    this.nextSeq.set(sessionId, seq + 1);
    return { seq, sessionId, ts: e.ts, kind: e.kind, payload: e.payload };
  }

  read(sessionId: string, fromSeq = 0): SessionEvent[] {
    const rows = this.db
      .prepare(
        "SELECT seq, ts, kind, payload FROM events WHERE session_id = ? AND seq > ? ORDER BY seq ASC",
      )
      .all(sessionId, fromSeq) as Array<{ seq: number; ts: number; kind: string; payload: string }>;
    return rows.map((r) => this.hydrate(sessionId, r));
  }

  /**
   * SPEC-cli-as-client D5: the last `limit` events, bounded by `LIMIT` in the query and
   * reversed in memory. `read().slice(-limit)` would return the same rows while
   * loading the entire log to do it — which is the cost D5 exists to remove, on
   * exactly the long sessions worth carrying context out of.
   */
  readTail(sessionId: string, limit: number): SessionEvent[] {
    if (limit <= 0) return [];
    const rows = this.db
      .prepare(
        "SELECT seq, ts, kind, payload FROM events WHERE session_id = ? ORDER BY seq DESC LIMIT ?",
      )
      .all(sessionId, limit) as Array<{ seq: number; ts: number; kind: string; payload: string }>;
    return rows.reverse().map((r) => this.hydrate(sessionId, r));
  }

  private hydrate(
    sessionId: string,
    r: { seq: number; ts: number; kind: string; payload: string },
  ): SessionEvent {
    return {
      seq: Number(r.seq),
      sessionId,
      ts: Number(r.ts),
      kind: r.kind as SessionEvent["kind"],
      payload: JSON.parse(r.payload) as Record<string, unknown>,
    };
  }

  saveSession(m: SessionMeta): void {
    this.db
      .prepare(
        `INSERT INTO sessions
           (id, project_id, agent, title, status, policy, created_at, last_activity_at, last_preview, resume_session_path, agent_session_id, branch, worktree_path, closed, parent_id, handoff_reason, origin)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           project_id = excluded.project_id,
           agent = excluded.agent,
           title = excluded.title,
           status = excluded.status,
           policy = excluded.policy,
           last_activity_at = excluded.last_activity_at,
           last_preview = excluded.last_preview,
           resume_session_path = excluded.resume_session_path,
           agent_session_id = excluded.agent_session_id,
           branch = excluded.branch,
           worktree_path = excluded.worktree_path,
           closed = excluded.closed,
           parent_id = excluded.parent_id,
           handoff_reason = excluded.handoff_reason,
           origin = excluded.origin`,
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
        m.agentSessionId ?? null,
        m.branch ?? null,
        m.worktreePath ?? null,
        m.closed ? 1 : 0,
        m.parentId ?? null,
        m.handoffReason ?? null,
        m.origin ?? null,
      );
  }

  loadSessions(): SessionMeta[] {
    const rows = this.db
      .prepare(
        `SELECT id, project_id, agent, title, status, policy, created_at, last_activity_at, last_preview, resume_session_path, agent_session_id, branch, worktree_path, closed, parent_id, handoff_reason, origin
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
      agentSessionId: (r.agent_session_id as string | null) ?? undefined,
      branch: (r.branch as string | null) ?? undefined,
      worktreePath: (r.worktree_path as string | null) ?? undefined,
      closed: Number(r.closed ?? 0) === 1,
      parentId: (r.parent_id as string | null) ?? undefined,
      handoffReason: (r.handoff_reason as string | null) ?? undefined,
      origin: (r.origin as SessionMeta["origin"] | null) ?? undefined,
    }));
  }

  deleteSession(id: string): void {
    this.nextSeq.delete(id);
    this.db.prepare("DELETE FROM events WHERE session_id = ?").run(id);
    this.db.prepare("DELETE FROM sessions WHERE id = ?").run(id);
  }

  close(): void {
    this.db.close();
  }
}
