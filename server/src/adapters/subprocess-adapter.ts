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
import type { AdapterEvent, AgentAdapter, SpawnOpts, UserInput } from "./adapter.js";
import { TurnStatusTracker } from "./turn-status.js";

export abstract class SubprocessAdapter extends EventEmitter implements AgentAdapter {
  abstract readonly agent: string;

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
  abstract kill(signal?: NodeJS.Signals): Promise<void>;

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
