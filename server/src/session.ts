/**
 * Session: one agent process + an in-memory append-only event log.
 *
 * M0: log is in memory only. Persistence comes in M4 (SQLite event log) as
 * planned in `docs/ARCHITECTURE.md`.
 */

import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import type { AgentAdapter, AdapterEvent } from "./adapters/adapter.js";
import type {
  ApprovalPolicy,
  SessionDTO,
  SessionEvent,
  SessionStatus,
} from "./protocol.js";
import { DEFAULT_SESSION_TITLE } from "./protocol.js";
import type { EventStore, NewEvent, SessionMeta } from "./storage/event_store.js";

/**
 * The draft → started state machine as a discriminated union (SPEC-17 P4).
 *
 * - `draft`: worktree + agent creation is deferred until the first substantive
 *   user message. `agent` is the harness to launch; `baseBranch` the branch to
 *   fork off; `pendingWorktreePath` (start-a-session-in-worktree flow) binds
 *   the draft to an EXISTING worktree, in which case `branch` is derived from
 *   git up front.
 * - `started`: the session is live in `worktreePath` on `branch`.
 *
 * `pendingWorktreePath` lives ONLY on the draft variant, so it is a compile
 * error to read it on a started session — the invariant is enforced by the
 * type, not by convention.
 */
export type SessionLifecycle =
  | {
      phase: "draft";
      agent: string;
      baseBranch?: string;
      pendingWorktreePath?: string;
      branch?: string;
    }
  | { phase: "started"; branch?: string; worktreePath?: string };

export interface SessionInit {
  projectId: string;
  agent: string;
  title?: string;
  adapter: AgentAdapter;
  policy?: ApprovalPolicy;
  /**
   * Optional durable event log. When present, every event is written to the
   * store (which assigns `seq`) BEFORE it is emitted, and session metadata is
   * upserted on change — so the session survives a server restart. When
   * absent, the session keeps its events in memory only (M0 behaviour).
   */
  store?: EventStore;
  /** Reuse a persisted id on rehydration; otherwise a fresh uuid is minted. */
  id?: string;
  createdAt?: number;
  /** Restore persisted derived state on rehydration. */
  status?: SessionStatus;
  lastActivityAt?: number;
  lastPreview?: string;
  /** On-disk transcript path so a cold session can be re-attached (pi resume). */
  resumeSessionPath?: string;
}

export class Session extends EventEmitter {
  readonly id: string;
  readonly projectId: string;
  agent: string;
  readonly createdAt: number;
  title: string;
  status: SessionStatus = "idle";
  policy: ApprovalPolicy;
  lastActivityAt = Date.now();
  lastPreview = "";
  /** On-disk transcript path used to relaunch a pi session (resume linkage). */
  readonly resumeSessionPath?: string;

  /**
   * Draft → started state machine (SPEC-17 P4). A fresh session is `started`
   * (live); {@link beginDraft} enters the draft phase and {@link markStarted}
   * transitions back out of it. The convention-enforced `pending*` fields are
   * derived from this union via the getters below (DTO shape is unchanged).
   */
  private _lifecycle: SessionLifecycle = { phase: "started" };

  readonly events: SessionEvent[] = [];
  adapter: AgentAdapter;
  private readonly store?: EventStore;

  constructor(init: SessionInit) {
    super();
    this.id = init.id ?? randomUUID();
    this.projectId = init.projectId;
    this.agent = init.agent;
    this.createdAt = init.createdAt ?? Date.now();
    this.title = init.title ?? DEFAULT_SESSION_TITLE;
    this.adapter = init.adapter;
    this.policy = init.policy ?? "ask-on-risky";
    this.store = init.store;
    if (init.status) this.status = init.status;
    if (typeof init.lastActivityAt === "number") this.lastActivityAt = init.lastActivityAt;
    if (typeof init.lastPreview === "string") this.lastPreview = init.lastPreview;
    this.resumeSessionPath = init.resumeSessionPath;

    this.persistMeta();
    this.bindAdapter(this.adapter);

  }

  /**
   * Load persisted events into the in-memory cache WITHOUT re-writing them to
   * the store (they are already durable). Used when rehydrating a session
   * after a server restart so `session.events` reflects prior history.
   */
  hydrate(events: SessionEvent[]): void {
    for (const e of events) this.events.push(e);
    const last = events.at(-1);
    if (last) this.lastActivityAt = Math.max(this.lastActivityAt, last.ts);
  }

  /**
   * Append an event durably (via the store, which assigns `seq`) or in memory
   * (fallback). Updates the in-memory cache + derived fields, but does NOT
   * emit — callers decide whether to fan out. Returns the formed event.
   */
  private record(e: NewEvent): SessionEvent {
    const event: SessionEvent = this.store
      ? this.store.append(this.id, e)
      : { seq: this.events.length + 1, sessionId: this.id, ts: e.ts, kind: e.kind, payload: e.payload };
    this.events.push(event);
    this.lastActivityAt = event.ts;
    let metaChanged = false;
    if (event.kind === "user.message" || event.kind === "agent.message") {
      const t = (event.payload as { text?: string }).text;
      if (typeof t === "string") {
        this.lastPreview = t.slice(0, 200);
        metaChanged = true;
      }
    } else if (event.kind === "session.status") {
      const s = (event.payload as { status?: SessionStatus }).status;
      if (s) {
        this.status = s;
        metaChanged = true;
      }
    }
    this.persistMeta();
    // Fan out a sessions-snapshot trigger ONLY when a DTO-visible field
    // (preview/status) actually changed — per-token deltas leave it untouched
    // (SPEC-17 P2: no O(clients × sessions) fan-out per streaming token).
    if (metaChanged) this.emit("metaChanged");
    return event;
  }

  private toMeta(): SessionMeta {
    return {
      id: this.id,
      projectId: this.projectId,
      agent: this.agent,
      title: this.title,
      status: this.status,
      policy: this.policy,
      createdAt: this.createdAt,
      lastActivityAt: this.lastActivityAt,
      lastPreview: this.lastPreview,
      resumeSessionPath: this.resumeSessionPath,
    };
  }

  private persistMeta(): void {
    this.store?.saveSession(this.toMeta());
  }

  replaceAdapter(adapter: AgentAdapter): void {
    this.adapter = adapter;
    this.bindAdapter(adapter);
  }

  /**
   * Record and emit a `session.error` through the normal event pipeline, so it
   * gets a real monotonic seq and is persisted (like any adapter event) rather
   * than being hand-built by a caller. Used e.g. when draft promotion fails.
   */
  recordError(message: string): void {
    this.emit("event", this.record({ ts: Date.now(), kind: "session.error", payload: { message } }));
  }

  /**
   * Seed the event log from a prior transcript BEFORE the adapter goes live.
   * Populates `this.events[]` (assigning seqs, sessionId, and bubbling up
   * status/preview) but does NOT emit — history is replayed to clients on
   * `sub` (see SubscriptionHub), so emitting here would double-fire.
   */
  backfill(events: AdapterEvent[]): void {
    for (const e of events) this.record(e);
  }

  private bindAdapter(adapter: AgentAdapter): void {
    adapter.on("event", (e) => {
      this.emit("event", this.record(e));
    });

    adapter.on("status", (s) => {
      const status = s === "running" ? "running" : "idle";
      this.status = status;
      this.emit("event", this.record({ ts: Date.now(), kind: "session.status", payload: { status } }));
    });

    adapter.on("title", (title) => this.setTitle(title));
  }

  /** Live lifecycle state (SPEC-17 P4). Read-only view for typed transitions. */
  get lifecycle(): SessionLifecycle {
    return this._lifecycle;
  }

  /** True while this session is a deferred draft (no worktree/agent yet). */
  get pending(): boolean {
    return this._lifecycle.phase === "draft";
  }

  /** Chosen harness for a still-pending draft; undefined once started. */
  get pendingAgent(): string | undefined {
    return this._lifecycle.phase === "draft" ? this._lifecycle.agent : undefined;
  }

  /** Branch this session runs on (draft-bound worktree, or set at start). */
  get branch(): string | undefined {
    return this._lifecycle.branch;
  }

  /** Absolute worktree path, set once the session has started. */
  get worktreePath(): string | undefined {
    return this._lifecycle.phase === "started" ? this._lifecycle.worktreePath : undefined;
  }

  /**
   * Enter the draft phase: defer worktree + agent creation until the first
   * substantive message (see {@link Manager.startPendingSession}).
   */
  beginDraft(opts: {
    agent: string;
    baseBranch?: string;
    pendingWorktreePath?: string;
    branch?: string;
  }): void {
    this._lifecycle = { phase: "draft", ...opts };
  }

  /** Change the harness a still-pending draft will start with. No-op once started. */
  setPendingAgent(agent: string): void {
    if (this._lifecycle.phase === "draft") {
      this._lifecycle = { ...this._lifecycle, agent };
    }
  }

  /**
   * Promote a pending (draft) session once its worktree + agent are live.
   * Records the branch/worktree it now runs in and clears the pending flag.
   */
  markStarted(opts: { branch: string; worktreePath: string; title?: string }): void {
    this._lifecycle = { phase: "started", branch: opts.branch, worktreePath: opts.worktreePath };
    if (opts.title) this.setTitle(opts.title);
    this.persistMeta();
    // Draft → started flips DTO-visible fields (pending/branch/worktree), so
    // trigger a sessions-snapshot re-broadcast (SPEC-17 P2).
    this.emit("metaChanged");
  }

  toDTO(): SessionDTO {
    return {
      id: this.id,
      projectId: this.projectId,
      agent: this.agent,
      title: this.title,
      status: this.status,
      policy: this.policy,
      lastActivityAt: this.lastActivityAt,
      lastPreview: this.lastPreview,
      pending: this.pending,
      pendingAgent: this.pendingAgent,
      branch: this.branch,
      worktreePath: this.worktreePath,
    };
  }

  async sendUserMessage(text: string) {
    await this.adapter.send({ text });
    // Adapter is responsible for echoing user.message into its event stream
    // so that turn boundaries are unambiguous.
  }

  /**
   * Run a built-in control action (e.g. `compact`, `thinking`) on the adapter.
   * Unlike {@link sendUserMessage} this is not a user turn — it maps to a pi
   * SDK call in the hosting extension. No-op if the adapter can't map actions.
   */
  async sendAction(action: string, args?: Record<string, unknown>) {
    await this.adapter.sendAction?.(action, args);
  }

  /**
   * Rename the session. Trims, ignores empty/unchanged titles, and emits
   * `titleChanged` so the server can re-broadcast the sessions snapshot and
   * sync the mux pane label. Returns whether the title actually changed.
   */
  setTitle(title: string): boolean {
    const next = title.trim();
    if (!next || next === this.title) return false;
    this.title = next;
    this.persistMeta();
    this.emit("titleChanged", next);
    // Title is a session-list (DTO) field — trigger the snapshot re-broadcast.
    this.emit("metaChanged");
    return true;
  }

  on(event: "event", listener: (e: SessionEvent) => void): this;
  on(event: "titleChanged", listener: (title: string) => void): this;
  on(event: "metaChanged", listener: () => void): this;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  on(event: string, listener: (...args: any[]) => void): this {
    return super.on(event, listener);
  }
}
