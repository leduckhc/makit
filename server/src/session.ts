/**
 * Session: one agent process + an in-memory append-only event log.
 *
 * M0: log is in memory only. Persistence comes in M4 (SQLite event log) as
 * planned in `docs/ARCHITECTURE.md`.
 */

import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import type { AgentAdapter, AdapterEvent } from "./adapters/adapter.js";
import { DetachedAdapter } from "./adapters/detached.js";
import type {
  ApprovalPolicy,
  QueuedMessageDTO,
  SessionDTO,
  SessionEvent,
  SessionOrigin,
  SessionStatus,
  SessionUsageDTO,
} from "./protocol.js";
import { DEFAULT_SESSION_TITLE } from "./protocol.js";
import type { EventStore, NewEvent, SessionMeta } from "./storage/event_store.js";
import type { MediaAttachment } from "./media/store.js";
import { StreamDigest, isStreamDelta, TURN_END_STATUSES } from "./stream_digest.js";

/**
 * Event kinds that advance lastActivityAt but must never fan out the sessions
 * snapshot (SPEC-server-hotpath-and-state P2 hot path): per-token streaming deltas, plus `session.usage`
 * (SPEC-context-usage), which arrives once per turn and changes no field of the session
 * list DTO — the turn's own events already trigger that broadcast.
 */
const NO_FANOUT_KINDS: ReadonlySet<string> = new Set([
  "agent.message.delta",
  "agent.thinking.delta",
  "tool.call.delta",
  "session.usage",
]);

/**
 * A message the user submitted while the agent was busy, held until the agent
 * goes idle (SPEC-mid-turn-steering-and-queue). Kept in memory only: unsent intent must not go stale in
 * a file across a restart.
 */
interface QueuedMessage {
  id: string;
  text: string;
  attachments?: MediaAttachment[];
  queuedAt: number;
}

/**
 * How many recent events a session keeps in memory when a store holds the rest.
 *
 * 500 covers a mid-turn subscribe (the deltas of one turn leave memory at its
 * close, see stream_digest.ts) while bounding what an opened transcript costs.
 * Anything older is read from the store on demand ({@link Session.eventsSince}).
 */
export const MEMORY_EVENT_CAP = 500;

/**
 * Statuses in which the agent is working (or blocked on the user) and therefore
 * cannot take a fresh turn (SPEC-mid-turn-steering-and-queue). `error`/`exited` are deliberately absent:
 * a dead session must not silently swallow messages into a queue that will
 * never flush.
 */
const BUSY_STATUSES: ReadonlySet<SessionStatus> = new Set<SessionStatus>([
  "running",
  "awaiting-input",
  "awaiting-approval",
]);

/**
 * The draft → started state machine as a discriminated union (SPEC-server-hotpath-and-state P4).
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
       * Pre-spawn config picks (SPEC-new-session-config-at-spawn): `{id, value}` requests, validated
       * against the cached catalog, applied at launch after the real
       * session/thread starts and before the first prompt.
       */
      configPicks?: { id: string; value: string | boolean }[];
      /**
       * SPEC-cli-as-client U4: a forked thread's native id. When set, promotion resumes
       * this thread (the adapter's `thread/resume`) instead of starting a fresh
       * one, so the child continues the forked conversation rather than a new
       * one that merely looks forked.
       */
      resumeAgentSessionId?: string;
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
  /** Native agent session/thread id, restored on rehydration for resume (SPEC-session-lifecycle-resume-list-delete). */
  agentSessionId?: string;
  /** Closed on rehydration (SPEC-session-lifecycle-resume-list-delete): hidden from the active list, still resumable. */
  closed?: boolean;
  /** Restore the started-session branch/worktree on rehydration. */
  branch?: string;
  worktreePath?: string;
  /**
   * SPEC-cli-as-client lineage (D10), restored on rehydration so a cold session still
   * reports who it was handed off from. Set once at construction — lineage is
   * immutable for a session's life.
   */
  parentId?: string;
  handoffReason?: string;
  origin?: SessionOrigin;
  /**
   * Lazy history source for rehydrated sessions. When present, the persisted
   * event log is NOT loaded at construction — it is read once, on first
   * access to {@link Session.events} (or first {@link record}). Keeps boot
   * O(sessions) instead of O(events) and avoids holding every transcript in
   * memory for sessions nobody opens.
   */
  hydrateFrom?: () => SessionEvent[];
}

/**
 * Hard ceiling on pending mid-turn messages per session (SPEC-mid-turn-steering-and-queue).
 *
 * The queue is in-memory and appendable by any authenticated client for as long
 * as it can keep the agent busy, so it needs a bound. High enough that no real
 * user meets it.
 */
const MAX_QUEUED_MESSAGES = 50;

/** First 80 chars of a queued message, for an error the user can act on. */
function preview(text: string): string {
  const one = text.replace(/\s+/g, " ").trim();
  return one.length > 80 ? `${one.slice(0, 79)}…` : one;
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
   * server restart (SPEC-session-lifecycle-resume-list-delete). Undefined for drafts and cold/history-only
   * sessions until re-attached.
   */
  agentSessionId?: string;

  /**
   * Closed (SPEC-session-lifecycle-resume-list-delete): the agent has been released and its process reclaimed.
   * A closed session is excluded from the active session list
   * (`SessionManager.listSessions`) but keeps its full event log + resume
   * handle, so `session.reopen` — or simply sending a message — resumes it.
   * Persisted so it stays closed across a restart.
   */
  closed = false;

  /**
   * SPEC-cli-as-client lineage (D10): the session this one was handed off / spawned from,
   * why, and which client created it. Immutable for the session's life, set at
   * construction and persisted so the app can caption "handed off from …" and
   * D9's depth/fan-out guard has something to count. Undefined for a session
   * with no parent (every pre-SPEC-cli-as-client row, and every app-spawned session).
   */
  readonly parentId?: string;
  readonly handoffReason?: string;
  readonly origin?: SessionOrigin;

  /** Pending lazy history loader — consumed (set to undefined) on first use. */
  private hydrateFrom?: () => SessionEvent[];

  /**
   * Draft → started state machine (SPEC-server-hotpath-and-state P4). A fresh session is `started`
   * (live); {@link beginDraft} enters the draft phase and {@link markStarted}
   * transitions back out of it. The convention-enforced `pending*` fields are
   * derived from this union via the getters below (DTO shape is unchanged).
   */
  private _lifecycle: SessionLifecycle = { phase: "started" };

  private readonly _events: SessionEvent[] = [];
  /**
   * The highest seq this session has ever issued, for the no-store path.
   *
   * NOT derived from `_events`: a seq is a client's dedup key, and the cache
   * SHRINKS. `closeStreams` removes the turn's deltas and puts one aggregate
   * back at the first delta's seq, so both `_events.length` and the last
   * element's seq can fall below a seq clients already hold. Counting from
   * either reissued those numbers, and every event of the next turn was then
   * discarded as already seen. With a store, `reserveSeq` plays this role.
   */
  private lastSeq = 0;
  /**
   * Which streamed text is still open, and what history needs when it closes.
   * A delta is emitted live but never written as its own row (see
   * stream_digest.ts).
   */
  private readonly digest = new StreamDigest();
  /** Mid-turn messages awaiting delivery (SPEC-mid-turn-steering-and-queue), oldest first. */
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
   * The in-memory event cache: the recent tail, not the whole history.
   *
   * For a lazily-rehydrated session the first access loads that tail (once)
   * before returning. Callers that need older events must use
   * {@link eventsSince}, which falls back to the store.
   */
  get events(): SessionEvent[] {
    this.ensureHydrated();
    return this._events;
  }

  /**
   * Events with `seq > fromSeq`, ascending — from memory when the cache reaches
   * back that far, else from the store.
   *
   * The replay path (`sub`) asks for the whole log on a first subscribe, and one
   * session here has 31,554 events. Serving that from a cache meant holding every
   * transcript the user ever opened for the life of the process; serving it from
   * the store costs one query on a path that already sends the same rows over a
   * socket.
   */
  eventsSince(fromSeq: number): SessionEvent[] {
    this.ensureHydrated();
    const oldest = this._events[0]?.seq;
    const complete = !this.truncated || oldest === undefined || fromSeq >= oldest - 1;
    if (complete) return this._events.filter((e) => e.seq > fromSeq);
    if (!this.store) return this._events.filter((e) => e.seq > fromSeq);

    // The store holds history, but a streamed delta is never written to it (see
    // stream_digest.ts). Serving the store alone would replay a mid-turn
    // subscriber everything EXCEPT the answer being typed, so the live tail is
    // merged back in. `seq` is unique per event, so it is the merge key; the
    // in-memory copy wins, being the one clients were fanned out.
    const merged = new Map<number, SessionEvent>();
    for (const e of this.store.read(this.id, fromSeq)) merged.set(e.seq, e);
    for (const e of this._events) if (e.seq > fromSeq) merged.set(e.seq, e);
    return [...merged.values()].sort((a, b) => a.seq - b.seq);
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
    this.closed = init.closed ?? false;
    this.parentId = init.parentId;
    this.handoffReason = init.handoffReason;
    this.origin = init.origin;
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
    // Never issue a seq that history already used. Loaded rows may arrive in any
    // order, so take the maximum rather than the last one.
    for (const e of events) if (e.seq > this.lastSeq) this.lastSeq = e.seq;
    // A tail read starts above seq 1, so the cache no longer reaches the log's
    // start and `eventsSince` must go to the store for anything older.
    if (this.store && (this._events[0]?.seq ?? 1) > 1) this.truncated = true;
  }

  /**
   * True when the cache no longer holds the session's oldest event, so the store
   * is the only complete history. False for a session with no store, where the
   * cache IS the history and must never be trimmed.
   */
  private truncated = false;

  /**
   * Drop the oldest events once the cache grows past twice the cap, so a long
   * turn costs one trim instead of one per event. Only with a store: without one
   * the cache is the history.
   *
   * Never while a stream is open. A delta is not persisted, so a delta this drops
   * cannot be read back — trimming mid-stream truncated the answer that a
   * mid-turn subscriber replays. The digest already holds the same text to build
   * the aggregate, so waiting for the close costs no new order of memory, and
   * {@link closeStreams} trims as soon as the aggregate replaces the deltas.
   */
  private trimCache(): void {
    if (!this.store) return;
    if (!this.digest.isEmpty) return;
    if (this._events.length <= MEMORY_EVENT_CAP * 2) return;
    this._events.splice(0, this._events.length - MEMORY_EVENT_CAP);
    this.truncated = true;
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
    const event = this.form(e);
    this._events.push(event);
    this.trimCache();

    // Snapshot the DTO-visible fields BEFORE mutating so we can emit
    // `metaChanged` only on an actual change (and never pre-assign status
    // ahead of the comparison).
    const prevStatus = this.status;
    const prevPreview = this.lastPreview;
    const prevActivity = this.lastActivityAt;

    // Some kinds must NOT fan out the sessions snapshot (SPEC-server-hotpath-and-state P2: no
    // O(clients × sessions) per-token cost). They still advance lastActivityAt;
    // the change is broadcast lazily on the next fan-out-eligible event.
    const isNoFanout = NO_FANOUT_KINDS.has(event.kind);

    this.lastActivityAt = event.ts;
    if (event.kind === "user.message" || event.kind === "agent.message") {
      const t = (event.payload as { text?: string }).text;
      if (typeof t === "string") this.lastPreview = t.slice(0, 200);
    } else if (event.kind === "session.status") {
      const s = (event.payload as { status?: SessionStatus }).status;
      if (s) this.status = s;
    }
    // A streamed token moves nothing but `lastActivityAt`, and the next real
    // event carries that. Persisting here meant a full 17-column session upsert
    // per token — 1.66 M of them across one profile log, for data nothing read.
    if (!isNoFanout) this.persistMeta();

    // Fan out a sessions-snapshot trigger for a real, non-streaming DTO change
    // (status/preview/lastActivityAt). Errors and tool events now refresh the
    // list too (they advance lastActivityAt), while identical values on the
    // same tick stay silent.
    const changed =
      this.status !== prevStatus ||
      this.lastPreview !== prevPreview ||
      this.lastActivityAt !== prevActivity;
    if (!isNoFanout && changed) this.emit("metaChanged");

    // The agent stopped: every stream is complete, so history can take its
    // aggregates and memory can drop the deltas (see stream_digest.ts). Done
    // after the event is in place, so the close cannot reorder the log.
    if (event.kind === "session.status" && TURN_END_STATUSES.has(this.status)) {
      this.closeStreams();
    }
    return event;
  }

  /**
   * Form the event: assign its seq, and persist it unless it is a streamed
   * delta (see stream_digest.ts). A delta still consumes a seq, because clients
   * dedup by seq and two events must never share one.
   */
  private form(e: NewEvent): SessionEvent {
    if (!this.store) {
      // No store: the in-memory log is the only history, so it keeps the
      // aggregate rather than the deltas — the same shape a persisted session
      // rehydrates with.
      const event: SessionEvent = {
        seq: ++this.lastSeq,
        sessionId: this.id,
        ts: e.ts,
        kind: e.kind,
        payload: e.payload,
      };
      return this.digestOf(event);
    }
    if (isStreamDelta(e.kind)) {
      const event: SessionEvent = {
        seq: this.store.reserveSeq(this.id),
        sessionId: this.id,
        ts: e.ts,
        kind: e.kind,
        payload: e.payload,
      };
      this.digest.noteDelta(event);
      return event;
    }
    const payload = this.digest.noteFinal(e.kind, e.payload ?? {});
    return this.store.append(this.id, { ...e, payload });
  }

  /** The no-store path's half of {@link form}: note the event, same rules. */
  private digestOf(event: SessionEvent): SessionEvent {
    if (isStreamDelta(event.kind)) {
      this.digest.noteDelta(event);
      return event;
    }
    return { ...event, payload: this.digest.noteFinal(event.kind, event.payload ?? {}) };
  }

  /**
   * End of turn: write one aggregate for every stream that produced no final,
   * then drop the turn's deltas from memory. The aggregate takes the seq of the
   * first delta it replaces, so no client receives a seq it has not seen.
   */
  private closeStreams(): void {
    if (this.digest.isEmpty) return;
    const { aggregates, replacedSeqs } = this.digest.close();
    if (replacedSeqs.size === 0) return;

    const written: SessionEvent[] = [];
    for (const { seq, event } of aggregates) {
      written.push(
        this.store
          ? this.store.appendAt(this.id, seq, event)
          : { seq, sessionId: this.id, ts: event.ts, kind: event.kind, payload: event.payload },
      );
    }

    // One pass: drop every delta of the turn, then splice the aggregates back in
    // at their own seq so the cache stays seq-ordered.
    const kept = this._events.filter((ev) => !replacedSeqs.has(ev.seq));
    for (const ev of written) {
      let at = kept.length;
      while (at > 0 && kept[at - 1].seq > ev.seq) at--;
      kept.splice(at, 0, ev);
    }
    this._events.length = 0;
    this._events.push(...kept);
    // The aggregates now carry the text, so the cap may apply again. The trim is
    // held off while a stream is open (see trimCache), and this is that moment.
    this.trimCache();
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
      closed: this.closed,
      // Only a STARTED session's location is persisted: a draft's bound branch
      // must not survive a restart as "started on that branch" (the constructor
      // infers phase "started" from these fields on rehydration).
      branch: this._lifecycle.phase === "started" ? this._lifecycle.branch : undefined,
      worktreePath: this.worktreePath,
      parentId: this.parentId,
      handoffReason: this.handoffReason,
      origin: this.origin,
    };
  }

  private persistMeta(): void {
    this.store?.saveSession(this.toMeta());
  }

  /**
   * Swap in a new adapter, detaching the outgoing one first. Without the unbind
   * the replaced adapter keeps feeding this session: its late events land in the
   * transcript as ghost entries, and its `exit` clears the pending queue the
   * INCOMING adapter is about to flush.
   */
  replaceAdapter(adapter: AgentAdapter): void {
    this.unbindAdapter(this.adapter);
    this.adapter = adapter;
    this.bindAdapter(adapter);
  }

  /**
   * The listeners this session installed on its CURRENT adapter, kept so they
   * can be removed individually on replacement. A blanket
   * `removeAllListeners(kind)` would also cancel subscriptions the session does
   * not own (a metrics collector, a probe, a test harness).
   */
  private bound?: {
    event: (e: AdapterEvent) => void;
    status: (s: string) => void;
    exit: () => void;
    title: (t: string) => void;
  };

  private unbindAdapter(adapter: AgentAdapter): void {
    const bound = this.bound;
    if (!bound) return;
    adapter.off("event", bound.event);
    adapter.off("status", bound.status);
    adapter.off("exit", bound.exit);
    adapter.off("title", bound.title);
    this.bound = undefined;
  }

  /**
   * Root pid of the agent's process tree, or `undefined` when the adapter has
   * no child process (the in-process `StubAdapter`) or the spawn faulted.
   * Delegates to the subprocess-backed adapters' `agentPid` getter; read
   * structurally because pid is NOT part of the shared `AgentAdapter` contract
   * (only acp/codex spawn a child). The metrics collector omits sessions with
   * no pid rather than reporting a misleading 0 (SPEC-performance-metrics-dashboard decision 11).
   */
  get agentPid(): number | undefined {
    return (this.adapter as { readonly agentPid?: number }).agentPid;
  }

  /**
   * Adopt the live adapter's native session/thread id (ACP `sessionId`, codex
   * `threadId`) as this session's durable resume handle (SPEC-session-lifecycle-resume-list-delete), persisting
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
   * Set the closed flag (SPEC-session-lifecycle-resume-list-delete) and persist it. Emits `metaChanged` so the
   * server re-broadcasts the active session list (which now excludes closed
   * sessions). Returns whether the flag actually changed.
   */
  setClosed(closed: boolean): boolean {
    if (this.closed === closed) return false;
    this.closed = closed;
    this.persistMeta();
    this.emit("metaChanged");
    return true;
  }

  /**
   * Drop the recorded worktree/branch so the session buckets under the repo
   * ROOT again (SPEC-session-lifecycle-resume-list-delete: restoring a session whose worktree was deleted runs it
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
   * Record and emit a `session.status` through the normal event pipeline, so it
   * gets a real monotonic seq and is persisted. Used when the manager knows the
   * session's liveness changed without the adapter saying so — e.g. a resume that
   * reported `idle` and then failed to start.
   */
  recordStatus(status: SessionStatus): void {
    this.emit("event", this.record({ ts: Date.now(), kind: "session.status", payload: { status } }));
  }

  /**
   * Record and emit a `session.usage` snapshot (SPEC-context-usage). Used by the loopback
   * bridge's `POST /usage` for pi, which reports no usage over ACP; the codex and
   * ACP paths arrive as ordinary adapter events instead. Latest-wins in the app,
   * and in `NO_FANOUT_KINDS` so it never re-broadcasts the sessions snapshot.
   */
  recordUsage(usage: SessionUsageDTO): void {
    this.emit(
      "event",
      this.record({ ts: Date.now(), kind: "session.usage", payload: { ...usage } }),
    );
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
    const onEvent = (e: AdapterEvent) => {
      this.emit("event", this.record(e));
    };

    const onStatus = (s: string) => {
      const status = s === "running" ? "running" : "idle";
      // Don't pre-assign this.status here — record() owns the mutation + the
      // before/after comparison that decides whether to fan out metaChanged.
      this.emit("event", this.record({ ts: Date.now(), kind: "session.status", payload: { status } }));
      // The agent is ready for a new turn: hand it the next queued message
      // (SPEC-mid-turn-steering-and-queue). One per transition — the next flush waits for the next idle.
      if (status === "idle" && this.queued.length > 0) void this.flushNext();
    };

    // A dead agent will never flush the queue; drop it rather than leave chips
    // pinned in the composer forever (SPEC-mid-turn-steering-and-queue).
    const onExit = () => this.clearQueue();

    const onTitle = (title: string) => this.setTitle(title);

    this.bound = { event: onEvent, status: onStatus, exit: onExit, title: onTitle };
    adapter.on("event", onEvent);
    adapter.on("status", onStatus);
    adapter.on("exit", onExit);
    adapter.on("title", onTitle);
  }

  /** Live lifecycle state (SPEC-server-hotpath-and-state P4). Read-only view for typed transitions. */
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
    resumeAgentSessionId?: string;
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
   * Whether this session can be brought back to a live agent (SPEC-session-lifecycle-resume-list-delete): it
   * holds either a native agent session/thread id or a legacy pi transcript
   * path. Mirrors exactly what {@link SessionManager.reattachSession} accepts —
   * one predicate, so the DTO can never advertise less than the server will do.
   */
  /**
   * No live agent process backs this session: it holds the detached placeholder
   * (rehydrated after a restart, closed, or a draft awaiting promotion).
   *
   * The honest signal, and the canonical one — an agent that merely exited keeps
   * its real adapter, so `status` alone cannot tell the two apart. Callers ask
   * here rather than each re-deriving it from the adapter's class.
   */
  get cold(): boolean {
    return this.adapter instanceof DetachedAdapter;
  }

  get resumable(): boolean {
    return this.agentSessionId != null || this.resumeSessionPath != null;
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
    // trigger a sessions-snapshot re-broadcast (SPEC-server-hotpath-and-state P2).
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
      createdAt: this.createdAt,
      lastActivityAt: this.lastActivityAt,
      lastPreview: this.lastPreview,
      pending: this.pending,
      pendingAgent: this.pendingAgent,
      branch: this.branch,
      worktreePath: this.worktreePath,
      // SPEC-session-lifecycle-resume-list-delete: a session with a persisted resume handle can be brought back
      // to a live agent after a server restart (cold ones are auto-attached).
      resumable: this.resumable,
      closed: this.closed,
      // SPEC-cli-as-client lineage (D10): carried on the DTO so the app can caption
      // "handed off from …" without a second lookup. Undefined for a session
      // with no parent.
      parentId: this.parentId,
      handoffReason: this.handoffReason,
      origin: this.origin,
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

    // SPEC-mid-turn-steering-and-queue. Three cases, in this order:
    //  1. a queue already exists OR flushing is active -> append (never overtake
    //     an earlier message, including in the window between `idle` and the
    //     flush's next turn starting)
    //  2. the agent is busy       -> try to steer into the running turn
    //  3. otherwise               -> a normal fresh turn
    if (this.queued.length > 0 || this.flushing) {
      this.enqueue(input);
      return;
    }
    if (BUSY_STATUSES.has(this.status)) {
      const steered = await this.adapter.steer(input);
      if (steered) return;
      // Steer failed: re-check the queue state before deciding. If another
      // message arrived during the async steer and started flushing, enqueue
      // this one behind it; otherwise enqueue as the first queued message.
      if (this.queued.length > 0 || this.flushing || BUSY_STATUSES.has(this.status)) {
        this.enqueue(input);
        return;
      }
      // The turn ended between the busy check and now; deliver immediately.
      await this.adapter.send(input);
      return;
    }
    await this.adapter.send(input);
    // Adapter is responsible for echoing user.message into its event stream
    // so that turn boundaries are unambiguous.
  }

  /** Pending mid-turn messages, oldest first (SPEC-mid-turn-steering-and-queue). */
  get queuedMessages(): readonly QueuedMessage[] {
    return this.queued;
  }

  private enqueue(input: { text: string; attachments?: MediaAttachment[] }): void {
    // Bounded: the queue is in-memory and a client can append to it for as long
    // as it can keep a session busy. Refusing the newest message (rather than
    // dropping the oldest) keeps the promise the queue makes about the messages
    // it already accepted, and tells the user which one did not make it.
    if (this.queued.length >= MAX_QUEUED_MESSAGES) {
      this.recordError(
        `not queued — ${MAX_QUEUED_MESSAGES} messages are already waiting: ${preview(input.text)}`,
      );
      return;
    }
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
   * Replace a pending message's text (SPEC-pending-queue-edit-reorder). Empty/whitespace text is a
   * cancel — the user cleared the field, and a blank pending message is not a
   * thing. Returns false for an id the queue no longer holds (it was delivered
   * between the tap and this call), which callers treat as a no-op, not an error.
   */
  updateQueued(id: string, text: string): boolean {
    const entry = this.queued.find((q) => q.id === id);
    if (!entry) return false;
    if (!text.trim()) return this.cancelQueued(id);
    entry.text = text;
    this.emit("metaChanged");
    return true;
  }

  /**
   * Reorder the queue (SPEC-pending-queue-edit-reorder). `ids` is a **hint**, not an assertion: the
   * queue can flush between the user's tap and this call, so named ids take the
   * given order first, entries the client did not mention keep their relative
   * order after them, and unknown ids are ignored. A reorder can therefore never
   * error or lose a message. Returns false when nothing known was named.
   */
  reorderQueue(ids: string[]): boolean {
    // Deduplicate the incoming ids array, keeping only the first occurrence of
    // each ID to prevent duplicate QueuedMessage entries.
    const seen = new Set<string>();
    const uniqueIds = ids.filter((id) => {
      if (seen.has(id)) return false;
      seen.add(id);
      return true;
    });
    const named = uniqueIds
      .map((id) => this.queued.find((q) => q.id === id))
      .filter((q): q is QueuedMessage => q !== undefined);
    if (named.length === 0) return false;
    const rest = this.queued.filter((q) => !named.includes(q));
    this.queued.length = 0;
    this.queued.push(...named, ...rest);
    this.emit("metaChanged");
    return true;
  }

  /**
   * Send one pending message NOW: interrupt the running turn, then let the
   * normal flush deliver that message first (SPEC-queue-tray-and-promote — the tray's ⤒).
   *
   * Deliberately *not* built on `cancel`'s path: the `cancel` command clears the
   * whole queue ("stop means stop"), which is the opposite of what promote
   * means. Promote reuses the two primitives that already exist — move to the
   * head, then abort — so the message still goes out through `flushNext` on the
   * adapter's own `idle`, and the rest of the queue survives behind it.
   *
   * Returns false, WITHOUT interrupting, when the id is not queued: that is the
   * race where the message flushed between the tap and this frame, and aborting
   * the user's turn on the strength of a stale tap would destroy work they never
   * asked to lose.
   */
  async promoteQueued(id: string): Promise<boolean> {
    if (!this.queued.some((q) => q.id === id)) return false;
    this.reorderQueue([id]);
    await this.adapter.cancel();
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
      // Terminal failure policy: clear the entire queue on an adapter.send
      // rejection. A rejection means the adapter cannot accept messages (broken
      // connection, process crash, etc.), so continuing to flush would fail
      // repeatedly. The user is notified of both the immediate failure and the
      // queue clearing.
      // The message is already off the queue (shifted above) and the rest are
      // about to be dropped, so the error text is the ONLY record the user has
      // of what they typed — name them.
      this.recordError(
        `queued message could not be sent: ${(err as Error)?.message ?? String(err)} — ${preview(next.text)}`,
      );
      if (this.queued.length > 0) {
        const dropped = this.queued.map((q) => preview(q.text)).join(" · ");
        this.recordError(
          `dropped ${this.queued.length} queued message(s) after the send failure: ${dropped}`,
        );
        // `clearQueue()` rather than a second copy of its body.
        this.clearQueue();
      }
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
