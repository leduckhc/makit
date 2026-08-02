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
  QueuedMessageDTO,
  SessionDTO,
  SessionEvent,
  SessionStatus,
} from "./protocol.js";
import { DEFAULT_SESSION_TITLE } from "./protocol.js";
import type { EventStore, NewEvent, SessionMeta } from "./storage/event_store.js";
import type { MediaAttachment } from "./media/store.js";

/**
 * Event kinds that are per-token streaming deltas. They advance lastActivityAt
 * but must never fan out the sessions snapshot (SPEC-17 P2 hot path).
 */
const STREAMING_DELTA_KINDS: ReadonlySet<string> = new Set([
  "agent.message.delta",
  "agent.thinking.delta",
  "tool.call.delta",
]);

/**
 * A message the user submitted while the agent was busy, held until the agent
 * goes idle (SPEC-35). Kept in memory only: unsent intent must not go stale in
 * a file across a restart.
 */
interface QueuedMessage {
  id: string;
  text: string;
  attachments?: MediaAttachment[];
  queuedAt: number;
}

/**
 * Statuses in which the agent is working (or blocked on the user) and therefore
 * cannot take a fresh turn (SPEC-35). `error`/`exited` are deliberately absent:
 * a dead session must not silently swallow messages into a queue that will
 * never flush.
 */
const BUSY_STATUSES: ReadonlySet<SessionStatus> = new Set<SessionStatus>([
  "running",
  "awaiting-input",
  "awaiting-approval",
]);

/**
 * The draft → started state machine as a discriminated union (SPEC-17 P4).
 *
 * - `draft`: agent creation is deferred until the first substantive user
 *   message. `agent` is the harness to launch; `pendingWorktreePath` binds the
 *   draft to the worktree the client resolved (creating it when needed) before
 *   spawning, in which case `branch` is derived from git up front. Without one
 *   the agent runs in the repo dir (non-git project / unborn HEAD).
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
      pendingWorktreePath?: string;
      branch?: string;
      /**
       * Pre-spawn config picks (SPEC-27): `{id, value}` requests, validated
       * against the cached catalog, applied at launch after the real
       * session/thread starts and before the first prompt.
       */
      configPicks?: { id: string; value: string | boolean }[];
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
  /** Native agent session/thread id, restored on rehydration for resume (SPEC-29). */
  agentSessionId?: string;
  /** Archived on rehydration (SPEC-29): hidden from the active list, still resumable. */
  archived?: boolean;
  /** Restore the started-session branch/worktree on rehydration. */
  branch?: string;
  worktreePath?: string;
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

  /**
   * Native agent session/thread id (ACP `sessionId`, codex `threadId`) once the
   * live adapter has started, so this makit session can be resumed after a
   * server restart (SPEC-29). Undefined for drafts and cold/history-only
   * sessions until re-attached.
   */
  agentSessionId?: string;

  /**
   * Archived (SPEC-29): a soft, recoverable hide. An archived session is
   * excluded from the active session list (`SessionManager.listSessions`) but
   * keeps its full event log + resume handle and can be restored. Persisted so
   * it stays archived across a restart.
   */
  archived = false;

  /** Pending lazy history loader — consumed (set to undefined) on first use. */
  private hydrateFrom?: () => SessionEvent[];

  /**
   * Draft → started state machine (SPEC-17 P4). A fresh session is `started`
   * (live); {@link beginDraft} enters the draft phase and {@link markStarted}
   * transitions back out of it. The convention-enforced `pending*` fields are
   * derived from this union via the getters below (DTO shape is unchanged).
   */
  private _lifecycle: SessionLifecycle = { phase: "started" };

  private readonly _events: SessionEvent[] = [];
  /** Mid-turn messages awaiting delivery (SPEC-35), oldest first. */
  private readonly queued: QueuedMessage[] = [];
  /**
   * True while a queued message is being handed to the adapter. The tracker
   * settles to `idle` on more than one path, so without this a duplicate `idle`
   * would fire two turns at once.
   */
  private flushing = false;
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
    this.agentSessionId = init.agentSessionId;
    this.archived = init.archived ?? false;
    if (init.branch !== undefined || init.worktreePath !== undefined) {
      this._lifecycle = { phase: "started", branch: init.branch, worktreePath: init.worktreePath };
    }
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

    // Snapshot the DTO-visible fields BEFORE mutating so we can emit
    // `metaChanged` only on an actual change (and never pre-assign status
    // ahead of the comparison).
    const prevStatus = this.status;
    const prevPreview = this.lastPreview;
    const prevActivity = this.lastActivityAt;

    // Per-token streaming deltas are high-frequency and must NOT fan out the
    // sessions snapshot (SPEC-17 P2: no O(clients × sessions) per-token cost).
    // They still advance lastActivityAt; the change is broadcast lazily on the
    // next non-streaming event.
    const isStreamingDelta = STREAMING_DELTA_KINDS.has(event.kind);

    this.lastActivityAt = event.ts;
    if (event.kind === "user.message" || event.kind === "agent.message") {
      const t = (event.payload as { text?: string }).text;
      if (typeof t === "string") this.lastPreview = t.slice(0, 200);
    } else if (event.kind === "session.status") {
      const s = (event.payload as { status?: SessionStatus }).status;
      if (s) this.status = s;
    }
    this.persistMeta();

    // Fan out a sessions-snapshot trigger for a real, non-streaming DTO change
    // (status/preview/lastActivityAt). Errors and tool events now refresh the
    // list too (they advance lastActivityAt), while identical values on the
    // same tick stay silent.
    const changed =
      this.status !== prevStatus ||
      this.lastPreview !== prevPreview ||
      this.lastActivityAt !== prevActivity;
    if (!isStreamingDelta && changed) this.emit("metaChanged");
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
      agentSessionId: this.agentSessionId,
      archived: this.archived,
      // Only a STARTED session's location is persisted: a draft's bound branch
      // must not survive a restart as "started on that branch" (the constructor
      // infers phase "started" from these fields on rehydration).
      branch: this._lifecycle.phase === "started" ? this._lifecycle.branch : undefined,
      worktreePath: this.worktreePath,
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
   * Adopt the live adapter's native session/thread id (ACP `sessionId`, codex
   * `threadId`) as this session's durable resume handle (SPEC-29), persisting
   * it so the session can be resumed after a server restart. Called by the
   * manager right after `adapter.start()` resolves. No-op when the adapter has
   * no id (e.g. the detached placeholder).
   */
  captureAgentSessionId(): void {
    const id = this.adapter.agentSessionId;
    if (!id || id === this.agentSessionId) return;
    this.agentSessionId = id;
    this.persistMeta();
    this.emit("metaChanged");
  }

  /**
   * Set the archived flag (SPEC-29) and persist it. Emits `metaChanged` so the
   * server re-broadcasts the active session list (which now excludes archived
   * sessions). Returns whether the flag actually changed.
   */
  setArchived(archived: boolean): boolean {
    if (this.archived === archived) return false;
    this.archived = archived;
    this.persistMeta();
    this.emit("metaChanged");
    return true;
  }

  /**
   * Drop the recorded worktree/branch so the session buckets under the repo
   * ROOT again (SPEC-29: restoring a session whose worktree was deleted runs it
   * at the repo root). Without this the stale path matches no live worktree, so
   * the session renders in no view. No-op for a draft or an already-root
   * session. Persists + emits so the active snapshot re-broadcasts.
   */
  detachToRoot(): void {
    if (this._lifecycle.phase !== "started") return;
    if (this._lifecycle.branch === undefined && this._lifecycle.worktreePath === undefined) {
      return;
    }
    this._lifecycle = { phase: "started", branch: undefined, worktreePath: undefined };
    this.persistMeta();
    this.emit("metaChanged");
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
      // Don't pre-assign this.status here — record() owns the mutation + the
      // before/after comparison that decides whether to fan out metaChanged.
      this.emit("event", this.record({ ts: Date.now(), kind: "session.status", payload: { status } }));
      // The agent is ready for a new turn: hand it the next queued message
      // (SPEC-35). One per transition — the next flush waits for the next idle.
      if (status === "idle" && this.queued.length > 0) void this.flushNext();
    });

    // A dead agent will never flush the queue; drop it rather than leave chips
    // pinned in the composer forever (SPEC-35).
    adapter.on("exit", () => this.clearQueue());

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
   * The worktree this session is bound to, whether it has started yet or not:
   * a started session's live path, else a draft's pending path. Undefined for a
   * draft with no worktree (non-git project / unborn HEAD).
   */
  get boundWorktreePath(): string | undefined {
    return this._lifecycle.phase === "started"
      ? this._lifecycle.worktreePath
      : this._lifecycle.pendingWorktreePath;
  }

  /**
   * Enter the draft phase: defer worktree + agent creation until the first
   * substantive message (see {@link Manager.startPendingSession}).
   */
  beginDraft(opts: {
    agent: string;
    pendingWorktreePath?: string;
    branch?: string;
    configPicks?: { id: string; value: string | boolean }[];
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
      // SPEC-29: a session with a persisted native id can be brought back to a
      // live agent after a server restart (the app auto-attaches cold ones).
      resumable: this.agentSessionId != null,
      // SPEC-33: informational — drives the app's "handed over as a file" label,
      // not the send path (which always materialises a file in v1).
      promptImage: this.adapter.promptCapabilities.image,
      archived: this.archived,
      queued: this.queued.map(
        (q): QueuedMessageDTO => ({
          id: q.id,
          text: q.text,
          queuedAt: q.queuedAt,
          ...(q.attachments?.length ? { attachmentCount: q.attachments.length } : {}),
        }),
      ),
    };
  }

  async sendUserMessage(text: string, attachments?: MediaAttachment[]) {
    const input = { text, ...(attachments?.length ? { attachments } : {}) };

    // SPEC-35. Three cases, in this order:
    //  1. a queue already exists  -> append (never overtake an earlier message,
    //     including in the window between `idle` and the flush's next turn)
    //  2. the agent is busy       -> try to steer into the running turn
    //  3. otherwise               -> a normal fresh turn
    if (this.queued.length > 0) {
      this.enqueue(input);
      return;
    }
    if (BUSY_STATUSES.has(this.status)) {
      if (await this.adapter.steer(input)) return;
      this.enqueue(input);
      return;
    }
    await this.adapter.send(input);
    // Adapter is responsible for echoing user.message into its event stream
    // so that turn boundaries are unambiguous.
  }

  /** Pending mid-turn messages, oldest first (SPEC-35). */
  get queuedMessages(): readonly QueuedMessage[] {
    return this.queued;
  }

  private enqueue(input: { text: string; attachments?: MediaAttachment[] }): void {
    this.queued.push({ id: randomUUID(), queuedAt: Date.now(), ...input });
    // Queue state rides the sessions snapshot (see SessionDTO.queued).
    this.emit("metaChanged");
  }

  /** Drop one pending message by id. Returns whether it was there. */
  cancelQueued(id: string): boolean {
    const i = this.queued.findIndex((q) => q.id === id);
    if (i < 0) return false;
    this.queued.splice(i, 1);
    this.emit("metaChanged");
    return true;
  }

  /**
   * Drop every pending message. Used by `cancel` (stop means stop — follow-ups
   * must not fire into an aborted context) and on adapter exit. Returns whether
   * anything was dropped.
   */
  clearQueue(): boolean {
    if (this.queued.length === 0) return false;
    this.queued.length = 0;
    this.emit("metaChanged");
    return true;
  }

  /**
   * Deliver the oldest pending message as a fresh turn. Called on every `idle`
   * transition, so exactly one message goes out per turn and the flush can
   * never outrun the agent.
   */
  private async flushNext(): Promise<void> {
    if (this.flushing) return;
    const next = this.queued.shift();
    if (!next) return;
    this.flushing = true;
    this.emit("metaChanged");
    try {
      await this.adapter.send({
        text: next.text,
        ...(next.attachments?.length ? { attachments: next.attachments } : {}),
      });
    } catch (err) {
      // The message is gone from the queue, so the user must be told rather than
      // left watching a chip that silently vanished.
      this.recordError(`queued message could not be sent: ${(err as Error)?.message ?? String(err)}`);
    } finally {
      this.flushing = false;
    }
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
   * `titleChanged` so the server can re-broadcast the sessions snapshot.
   * Returns whether the title actually changed.
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
