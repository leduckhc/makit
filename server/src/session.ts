/**
 * Session: one agent process + an in-memory append-only event log.
 *
 * M0: log is in memory only. Persistence comes in M4 (SQLite event log) as
 * planned in `docs/ARCHITECTURE.md`.
 */

import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import type { AgentAdapter } from "./adapters/adapter.js";
import type {
  ApprovalPolicy,
  SessionDTO,
  SessionEvent,
  SessionStatus,
} from "./protocol.js";

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
  readonly adapter: AgentAdapter;

  constructor(init: SessionInit) {
    super();
    this.projectId = init.projectId;
    this.agent = init.agent;
    this.title = init.title ?? `${init.agent} session`;
    this.adapter = init.adapter;
    this.policy = init.policy ?? "ask-on-risky";

    this.adapter.on("event", (e) => {
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
      } else if (event.kind === "approval.request") {
        this.status = "awaiting-approval";
      }

      this.emit("event", event);
    });

    this.adapter.on("status", (s) => {
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
    };
  }

  async sendUserMessage(text: string) {
    await this.adapter.send({ text });
    // Adapter is responsible for echoing user.message into its event stream
    // so that turn boundaries are unambiguous.
  }

  on(event: "event", listener: (e: SessionEvent) => void): this {
    return super.on(event, listener);
  }
}
