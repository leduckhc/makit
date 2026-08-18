/**
 * SqliteEventStore — {@link EventStore} backed by Node's built-in `node:sqlite`.
 *
 * Uses a single database file (default `:memory:` for tests). Synchronous by
 * design so `append` can return the assigned `seq` inline, preserving the
 * write-before-fanout invariant. No native dependency: `node:sqlite` ships with
 * Node ≥ 22.5 and is stable on the project's Node floor.
 */

import { DatabaseSync, type StatementSync } from "node:sqlite";
import type { SessionEvent } from "../protocol.js";
import type { EventStore, NewEvent, SessionMeta } from "./event_store.js";

/**
 * How many seqs one persisted high-water mark covers.
 *
 * A streamed delta takes a seq and writes no row, so the mark is what stops a
 * restart from reissuing those numbers. Writing it per delta would cost the very
 * commit that not writing the delta saved, so it is written once per block. The
 * only price is a gap in the numbering after a crash, and the log has never been
 * required to be dense.
 */
export const SEQ_BLOCK = 256;

export class SqliteEventStore implements EventStore {
  private readonly db: DatabaseSync;
  /** Next seq per session — avoids a MAX(seq) query on every append. */
  private readonly nextSeq = new Map<string, number>();
  /** Per-session persisted seq ceiling, so the mark is written once per block. */
  private readonly hwm = new Map<string, number>();
  /**
   * Prepared statements by SQL text. Every write used to call `db.prepare`, so
   * an agent streaming a turn recompiled the same two statements per token.
   */
  private readonly statements = new Map<string, StatementSync>();

  constructor(path = ":memory:") {
    this.db = new DatabaseSync(path);
    this.db.exec("PRAGMA journal_mode = WAL;");
    // WAL + NORMAL is the pairing WAL exists for: a commit writes to the log and
    // returns, and the OS flushes it. The default FULL fsyncs EVERY commit, which
    // an agent streaming tokens pays per event. NORMAL risks only the last
    // commits in an OS crash or power loss — never in a process crash — and this
    // log is a transcript, not a ledger.
    this.db.exec("PRAGMA synchronous = NORMAL;");
    this.db.exec("PRAGMA foreign_keys = ON;");
    this.migrate();
  }

  /** A prepared statement for [sql], compiled once per store. */
  private stmt(sql: string): StatementSync {
    let s = this.statements.get(sql);
    if (s === undefined) {
      s = this.db.prepare(sql);
      this.statements.set(sql, s);
    }
    return s;
  }

  /** How many distinct statements this store has compiled (for the test). */
  get compiledStatementCount(): number {
    return this.statements.size;
  }

  /** Read one pragma, as a string. For the tests that pin the write path. */
  pragma(name: string): string {
    const row = this.db.prepare(`PRAGMA ${name}`).get() as Record<string, unknown> | undefined;
    return String(Object.values(row ?? {})[0] ?? "");
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
        closed       INTEGER NOT NULL DEFAULT 0,
        seq_hwm      INTEGER
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
    // The seq high-water mark. A streamed delta takes a seq and is never written,
    // so `MAX(seq)` under-reports what clients were sent (see reserveSeq).
    if (!cols.some((c) => c.name === "seq_hwm")) {
      this.db.exec("ALTER TABLE sessions ADD COLUMN seq_hwm INTEGER");
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
    // The row itself records the seq, so `MAX(seq)` recovers it after a restart
    // and no high-water mark is needed (see reserveSeq for the delta path).
    const seq = this.nextSeqFor(sessionId);
    return this.appendAt(sessionId, seq, e);
  }

  /**
   * Take the next seq for an event that will NOT be written: a streamed delta.
   *
   * The row is what normally remembers a seq, so an unwritten one needs the
   * persisted mark, or a restart mid-turn hands the same numbers out again and
   * every client discards the events as already seen.
   */
  reserveSeq(sessionId: string): number {
    const seq = this.nextSeqFor(sessionId);
    this.reserveBlockIfNeeded(sessionId, seq);
    return seq;
  }

  /** The next seq for this session, from the cache or from what survived. */
  private nextSeqFor(sessionId: string): number {
    let seq = this.nextSeq.get(sessionId);
    if (seq === undefined) {
      const row = this.stmt(
        "SELECT COALESCE(MAX(seq), 0) AS maxSeq FROM events WHERE session_id = ?",
      ).get(sessionId) as { maxSeq: number };
      // A delta consumes a seq without leaving a row, so MAX(seq) alone would
      // reissue the numbers of a turn that was streaming when the server died.
      seq = Math.max(Number(row.maxSeq), this.persistedHwm(sessionId)) + 1;
    }
    this.nextSeq.set(sessionId, seq + 1);
    return seq;
  }

  /** The high-water mark this session persisted, or 0 when it has none. */
  private persistedHwm(sessionId: string): number {
    const row = this.stmt("SELECT seq_hwm AS hwm FROM sessions WHERE id = ?").get(sessionId) as
      | { hwm: number | null }
      | undefined;
    return Number(row?.hwm ?? 0);
  }

  /**
   * Keep a persisted ceiling above the seqs handed out, in blocks.
   *
   * Writing the mark per delta would undo the point of not writing the delta, so
   * one row update covers {@link SEQ_BLOCK} reservations. After a crash the next
   * seq resumes at the block ceiling: it skips a few numbers, which the log has
   * never required to be dense, and it can never repeat one.
   */
  private reserveBlockIfNeeded(sessionId: string, seq: number): void {
    const known = this.hwm.get(sessionId);
    if (known !== undefined && seq < known) return;
    const ceiling = seq + SEQ_BLOCK;
    this.stmt("UPDATE sessions SET seq_hwm = ? WHERE id = ?").run(ceiling, sessionId);
    this.hwm.set(sessionId, ceiling);
  }

  appendAt(sessionId: string, seq: number, e: NewEvent): SessionEvent {
    this.stmt(
      "INSERT INTO events (session_id, seq, ts, kind, payload) VALUES (?, ?, ?, ?, ?)",
    ).run(sessionId, seq, e.ts, e.kind, JSON.stringify(e.payload ?? {}));
    // A reserved seq may be written out of order (an aggregate lands after the
    // events that followed its deltas), so never let it pull the counter back.
    const next = this.nextSeq.get(sessionId) ?? 0;
    if (seq + 1 > next) this.nextSeq.set(sessionId, seq + 1);
    return { seq, sessionId, ts: e.ts, kind: e.kind, payload: e.payload };
  }

  read(sessionId: string, fromSeq = 0): SessionEvent[] {
    const rows = this.stmt(
      "SELECT seq, ts, kind, payload FROM events WHERE session_id = ? AND seq > ? ORDER BY seq ASC",
    ).all(sessionId, fromSeq) as Array<{ seq: number; ts: number; kind: string; payload: string }>;
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
    const rows = this.stmt(
      "SELECT seq, ts, kind, payload FROM events WHERE session_id = ? ORDER BY seq DESC LIMIT ?",
    ).all(sessionId, limit) as Array<{ seq: number; ts: number; kind: string; payload: string }>;
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
    this.stmt(
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
    ).run(
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

  /**
   * Run `fn` inside one SQLite transaction: all of its writes land, or none do.
   *
   * Used by compaction, which deletes a turn's delta rows and then inserts the
   * aggregate carrying their text. Nested calls are not supported and not
   * needed — SQLite has no nested `BEGIN`.
   */
  transaction<T>(fn: () => T): T {
    this.db.exec("BEGIN IMMEDIATE;");
    try {
      const out = fn();
      this.db.exec("COMMIT;");
      return out;
    } catch (err) {
      // A failed ROLLBACK must not mask the error that caused it.
      try {
        this.db.exec("ROLLBACK;");
      } catch {
        // Already rolled back, or the connection is gone.
      }
      throw err;
    }
  }

  /**
   * Remove the given seqs of one session. Maintenance only — see `compact.ts`;
   * the log is append-only for every other caller.
   */
  deleteEvents(sessionId: string, seqs: number[]): void {
    if (seqs.length === 0) return;
    const stmt = this.db.prepare("DELETE FROM events WHERE session_id = ? AND seq = ?");
    for (const seq of seqs) stmt.run(sessionId, seq);
  }

  /** Replace one row's payload, keeping its seq, ts and kind (maintenance only). */
  replacePayload(sessionId: string, seq: number, payload: Record<string, unknown>): void {
    this.db
      .prepare("UPDATE events SET payload = ? WHERE session_id = ? AND seq = ?")
      .run(JSON.stringify(payload), sessionId, seq);
  }

  /** Every session id that has at least one event. */
  eventSessionIds(): string[] {
    const rows = this.db
      .prepare("SELECT DISTINCT session_id AS id FROM events ORDER BY session_id")
      .all() as Array<{ id: string }>;
    return rows.map((r) => r.id);
  }

  /**
   * Reclaim the space removed rows held. SQLite keeps freed pages in the file
   * otherwise, so a compaction would report success and free no disk.
   */
  vacuum(): void {
    this.db.exec("VACUUM;");
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
