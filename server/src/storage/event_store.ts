/**
 * EventStore — durable, append-only session event log + session registry.
 *
 * This is the persistence seam that lets makit survive a server restart: the
 * append-only event stream and the session metadata are written to SQLite so a
 * reconnecting client (mobile or desktop) can resume by `seq` and see the full
 * history even after the process — and every in-memory session — is gone.
 *
 * Invariant (see docs/ARCHITECTURE.md §4): an event is written to the log
 * BEFORE it is fanned out to clients. `append` is synchronous so callers get
 * the assigned `seq` back inline and can fan out immediately after.
 */

import type { SessionEvent, SessionStatus, ApprovalPolicy, SessionOrigin } from "../protocol.js";

/** Persisted session metadata (runtime-only `pane` is intentionally excluded). */
export interface SessionMeta {
  id: string;
  projectId: string;
  agent: string;
  title: string;
  status: SessionStatus;
  policy: ApprovalPolicy;
  createdAt: number;
  lastActivityAt: number;
  lastPreview: string;
  /**
   * On-disk transcript path used to relaunch a pi session with `--session`.
   * Persisted so a cold (rehydrated) session can be re-attached to a live agent
   * after a server restart. Null/absent for agents that can't resume this way.
   */
  resumeSessionPath?: string;
  /**
   * Native agent session/thread id (ACP `sessionId`, codex `threadId`).
   * Persisted so a cold (rehydrated) session can be resumed on the live agent
   * after a server restart (SPEC-session-lifecycle-resume-list-delete). Null/absent for drafts + agents that
   * never produced one.
   */
  agentSessionId?: string;
  /**
   * Git branch + worktree the session runs in (set on markStarted). Persisted
   * so a rehydrated session still reports its branch/worktree after a server
   * restart instead of falling back to the project's default branch.
   */
  branch?: string;
  worktreePath?: string;
  /**
   * Closed (SPEC-session-lifecycle-resume-list-delete): hidden from the active session list but kept + resumable
   * and restorable via `session.reopen`. Persisted so it survives a restart.
   */
  closed?: boolean;
  /**
   * SPEC-cli-as-client lineage (D10), persisted so the app can draw the handoff chain and
   * so D9's depth/fan-out guard has something to count. Added by an in-place
   * `ALTER TABLE` migration: a row written before SPEC-cli-as-client rehydrates with all
   * three `undefined`, which is why nothing may treat a missing `origin` as an
   * error.
   */
  parentId?: string;
  handoffReason?: string;
  origin?: SessionOrigin;
}

/** A new event to append: seq + sessionId are assigned/owned by the store. */
export type NewEvent = Omit<SessionEvent, "seq" | "sessionId">;

export interface EventStore {
  /**
   * Append an event to a session's log, assigning the next monotonic `seq`.
   * Returns the fully-formed, persisted event (with seq + sessionId).
   */
  append(sessionId: string, e: NewEvent): SessionEvent;
  /**
   * Take the next `seq` WITHOUT writing a row.
   *
   * For a streamed delta, which is emitted live but never persisted (see
   * `stream_digest.ts`). The seq still has to be consumed: clients dedup by seq,
   * so two events must never share one.
   */
  reserveSeq(sessionId: string): number;
  /**
   * Write an event at an already-issued `seq` — the slot a streamed delta took.
   * Used to persist one aggregate in place of the deltas it replaces, so no
   * client ever receives a seq it has not already seen.
   */
  appendAt(sessionId: string, seq: number, e: NewEvent): SessionEvent;
  /** Events with `seq > fromSeq`, ascending. `fromSeq = 0` returns all. */
  read(sessionId: string, fromSeq?: number): SessionEvent[];
  /**
   * The last `limit` events, ascending — bounded in the query, not by slicing a
   * full read afterwards (SPEC-cli-as-client D5). Returns the whole log when it is shorter
   * than `limit`.
   */
  readTail(sessionId: string, limit: number): SessionEvent[];
  /** Insert-or-update session metadata. */
  saveSession(meta: SessionMeta): void;
  /** All persisted session metadata, most-recently-active first. */
  loadSessions(): SessionMeta[];
  /** Remove a session and its events. */
  deleteSession(id: string): void;
  /** Release underlying resources. */
  close(): void;
}
