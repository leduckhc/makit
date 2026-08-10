/**
 * SubprocessAdapter — the shared base for every subprocess-backed
 * `AgentAdapter` (pi, acp, codex). It owns the lifecycle bookkeeping the three
 * adapters used to each re-implement:
 *
 *   - `emitEvent` — the single "emit a normalized AdapterEvent" seam
 *   - the `exited` flag + `handleExit` — settle the adapter exactly once
 *     (emit an `exited` session.status + the `exit` event)
 *   - a {@link TurnStatusTracker} — the turns/approvals → running/idle machine
 *
 * Subclasses layer their protocol-specific transport + mapper on top. Agents
 * with a fundamentally different exit story (pi respawns; it does not settle to
 * a terminal `exited` state) may keep their own exit reaction and simply use
 * `emitEvent`.
 */

import { EventEmitter } from "node:events";
import { NO_SESSION_CAPABILITIES, type AdapterEvent, type AgentAdapter, type SessionCapabilities, type SpawnOpts, type UserInput } from "./adapter.js";
import { TurnStatusTracker } from "./turn-status.js";

export abstract class SubprocessAdapter extends EventEmitter implements AgentAdapter {
  abstract readonly agent: string;

  /**
   * Session-lifecycle capabilities (SPEC-29). Subclasses overwrite this: codex
   * sets a static value; ACP populates it from the `initialize` response. The
   * safe default is all-false so a subclass that forgets degrades gracefully.
   */
  capabilities: SessionCapabilities = { ...NO_SESSION_CAPABILITIES };

  /** Prompt media support (SPEC-33). Subclasses that accept images override it. */

  /** Native session/thread id, set by the subclass once `start()` resolves. */
  agentSessionId?: string;

  /** Set once the subprocess has terminated; suppresses further transitions. */
  protected exited = false;

  /** The shared turns/approvals → running/idle/awaiting-* state machine. */
  protected readonly turns: TurnStatusTracker;

  constructor() {
    super();
    this.turns = new TurnStatusTracker({
      emitStatus: (s) => this.emit("status", s),
      emitSessionStatus: (status) =>
        this.emitEvent({ ts: Date.now(), kind: "session.status", payload: { status } }),
      isExited: () => this.exited,
    });
  }

  abstract start(opts: SpawnOpts): Promise<void>;
  abstract send(input: UserInput): Promise<void>;
  abstract cancel(): Promise<void>;
  /**
   * Graceful agent-side session release before the reap. Defaults to a no-op so
   * a transport without the primitive degrades to "just kill it"; subclasses
   * with a real close (ACP `session/close`, codex `thread/unsubscribe`)
   * override. Must never throw — see {@link AgentAdapter.close}.
   */
  async close(): Promise<void> {}
  abstract kill(signal?: NodeJS.Signals): Promise<void>;

  /**
   * No mid-turn injection by default (SPEC-35): the caller queues instead.
   * Only codex overrides this (`turn/steer`).
   */
  async steer(_input: UserInput): Promise<boolean> {
    return false;
  }

  /** Emit one normalized adapter event; the server fills in seq + sessionId. */
  protected emitEvent(e: AdapterEvent): void {
    this.emit("event", e);
  }

  /**
   * Settle the adapter as exited exactly once: run [onFirstExit] (e.g. reject
   * in-flight requests), emit an `exited` session.status, and emit `exit`.
   */
  protected handleExit(code: number | null, onFirstExit?: () => void): void {
    if (this.exited) return;
    this.exited = true;
    onFirstExit?.();
    this.emitEvent({ ts: Date.now(), kind: "session.status", payload: { status: "exited" } });
    this.emit("exit", code);
  }
}
