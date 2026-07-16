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
  /**
   * Lazy history source for rehydrated sessions. When present, the persisted
   * event log is NOT loaded at construction — it is read once, on first
   * access to {@link Session.events} (or first {@link record}). Keeps boot
   * O(sessions) instead of O(events) and avoids holding every transcript in
   * memory for sessions nobody opens.
   */
  hydrateFrom?: () => SessionEvent[];
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

  /** Pending lazy history loader — consumed (set to undefined) on first use. */
  private hydrateFrom?: () => SessionEvent[];

  /**
   * Draft state: worktree + agent creation is deferred until the first
   * substantive user message. Cleared by {@link markStarted}.
   */
  pending = false;
  /** Agent id to launch once the pending session starts. */
  pendingAgent?: string;
  /** Base branch to fork the worktree off, chosen at spawn. Defaults to the
   * repo's default branch when unset (see {@link Manager.startPendingSession}). */
  pendingBaseBranch?: string;
  /** When set, a pending session starts in this EXISTING worktree instead of
   * creating a new one (start-a-session-in-worktree flow). */
  pendingWorktreePath?: string;
  /** Branch this session runs on, set when its worktree is created. */
  branch?: string;
  /** Absolute worktree path, set when its worktree is created. */
  worktreePath?: string;

  private readonly _events: SessionEvent[] = [];
  adapter: AgentAdapter;
  private readonly store?: EventStore;

  /**
   * The in-memory event cache. For a lazily-rehydrated session the first
   * access loads the persisted history (once) before returning.
   */
  get events(): SessionEvent[] {
    this.ensureHydrated();
    return this._events;
  }

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
    this.hydrateFrom = init.hydrateFrom;

    this.persistMeta();
    this.bindAdapter(this.adapter);

  }

  /**
   * Load persisted events into the in-memory cache WITHOUT re-writing them to
   * the store (they are already durable). Used when rehydrating a session
   * after a server restart so `session.events` reflects prior history.
   */
  hydrate(events: SessionEvent[]): void {
    for (const e of events) this._events.push(e);
    const last = events.at(-1);
    if (last) this.lastActivityAt = Math.max(this.lastActivityAt, last.ts);
  }

  /** Run the pending lazy loader (if any) exactly once. History must precede
   *  anything recorded since boot, and record() hydrates first, so a plain
   *  hydrate() keeps ordering correct. */
  private ensureHydrated(): void {
    if (!this.hydrateFrom) return;
    const load = this.hydrateFrom;
    // Clear the loader only AFTER a successful read: if load() throws (e.g. a
    // transient store error) the loader is retained so a later access/record()
    // can retry, rather than permanently truncating this session's history.
    const events = load();
    this.hydrateFrom = undefined;
    this.hydrate(events);
  }

  /**
   * Append an event durably (via the store, which assigns `seq`) or in memory
   * (fallback). Updates the in-memory cache + derived fields, but does NOT
   * emit — callers decide whether to fan out. Returns the formed event.
   */
  private record(e: NewEvent): SessionEvent {
    // Load persisted history first so the cache stays complete + ordered even
    // when a cold session records before anyone read `events`.
    this.ensureHydrated();
    const event: SessionEvent = this.store
      ? this.store.append(this.id, e)
      : { seq: this._events.length + 1, sessionId: this.id, ts: e.ts, kind: e.kind, payload: e.payload };
    this._events.push(event);
    this.lastActivityAt = event.ts;
    if (event.kind === "user.message" || event.kind === "agent.message") {
      const t = (event.payload as { text?: string }).text;
      if (typeof t === "string") this.lastPreview = t.slice(0, 200);
    } else if (event.kind === "session.status") {
      const s = (event.payload as { status?: SessionStatus }).status;
      if (s) this.status = s;
    }
    this.persistMeta();
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

  /**
   * Promote a pending (draft) session once its worktree + agent are live.
   * Records the branch/worktree it now runs in and clears the pending flag.
   */
  markStarted(opts: { branch: string; worktreePath: string; title?: string }): void {
    this.branch = opts.branch;
    this.worktreePath = opts.worktreePath;
    this.pending = false;
    this.pendingAgent = undefined;
    if (opts.title) this.setTitle(opts.title);
    this.persistMeta();
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
    return true;
  }

  on(event: "event", listener: (e: SessionEvent) => void): this;
  on(event: "titleChanged", listener: (title: string) => void): this;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  on(event: string, listener: (...args: any[]) => void): this {
    return super.on(event, listener);
  }
}
