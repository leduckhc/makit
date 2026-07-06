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
import type { PaneHandle } from "./mux/adapter.js";

export interface SessionInit {
  projectId: string;
  agent: string;
  title?: string;
  adapter: AgentAdapter;
  policy?: ApprovalPolicy;
}

export class Session extends EventEmitter {
  readonly id = randomUUID();
  readonly projectId: string;
  readonly agent: string;
  title: string;
  status: SessionStatus = "idle";
  policy: ApprovalPolicy;
  lastActivityAt = Date.now();
  lastPreview = "";

  readonly events: SessionEvent[] = [];
  adapter: AgentAdapter;
  /** Set when this session runs in a multiplexer pane (SPEC-05). */
  pane?: PaneHandle;

  constructor(init: SessionInit) {
    super();
    this.projectId = init.projectId;
    this.agent = init.agent;
    this.title = init.title ?? DEFAULT_SESSION_TITLE;
    this.adapter = init.adapter;
    this.policy = init.policy ?? "ask-on-risky";

    this.bindAdapter(this.adapter);

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
    for (const e of events) {
      const event: SessionEvent = {
        seq: this.events.length + 1,
        sessionId: this.id,
        ts: e.ts,
        kind: e.kind,
        payload: e.payload,
      };
      this.events.push(event);
      this.lastActivityAt = event.ts;
      if (event.kind === "user.message" || event.kind === "agent.message") {
        const t = (event.payload as { text?: string }).text;
        if (typeof t === "string") this.lastPreview = t.slice(0, 200);
      } else if (event.kind === "session.status") {
        const s = (event.payload as { status?: SessionStatus }).status;
        if (s) this.status = s;
      }
    }
  }

  private bindAdapter(adapter: AgentAdapter): void {
    adapter.on("event", (e) => {
      const event: SessionEvent = {
        seq: this.events.length + 1,
        sessionId: this.id,
        ts: e.ts,
        kind: e.kind,
        payload: e.payload,
      };
      this.events.push(event);
      this.lastActivityAt = event.ts;

      // Bubble up status + preview for the home list.
      if (event.kind === "user.message" || event.kind === "agent.message") {
        const t = (event.payload as { text?: string }).text;
        if (typeof t === "string") this.lastPreview = t.slice(0, 200);
      } else if (event.kind === "session.status") {
        const s = (event.payload as { status?: SessionStatus }).status;
        if (s) this.status = s;
      }

      this.emit("event", event);
    });

    adapter.on("status", (s) => {
      this.status = s === "running" ? "running" : "idle";
      const evt: SessionEvent = {
        seq: this.events.length + 1,
        sessionId: this.id,
        ts: Date.now(),
        kind: "session.status",
        payload: { status: this.status },
      };
      this.events.push(evt);
      this.emit("event", evt);
    });

    adapter.on("title", (title) => this.setTitle(title));
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
      ...(this.pane ? { pane: { mux: this.pane.mux, paneId: this.pane.paneId } } : {}),
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
