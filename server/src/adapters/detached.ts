/**
 * DetachedAdapter — a no-process adapter for sessions rehydrated from the
 * durable event log after a server restart. The original agent process is
 * gone, so the session is read-only history: it replays fine to any client
 * (mobile or desktop), but attempting to send input emits a `session.error`
 * telling the client the session must be re-attached to continue.
 */

import { EventEmitter } from "node:events";
import { NO_SESSION_CAPABILITIES, type AgentAdapter, type SessionCapabilities, type SpawnOpts, type UserInput } from "./adapter.js";

export class DetachedAdapter extends EventEmitter implements AgentAdapter {
  readonly agent: string;
  /** Cold sessions can do nothing until re-attached (SPEC-session-lifecycle-resume-list-delete). */
  readonly capabilities: SessionCapabilities = NO_SESSION_CAPABILITIES;
  readonly agentSessionId = undefined;

  constructor(agent = "pi") {
    super();
    this.agent = agent;
  }

  async start(_opts: SpawnOpts): Promise<void> {
    // Cold session: nothing to spawn. Status is restored by the manager.
  }

  async send(_input: UserInput): Promise<void> {
    this.emit("event", {
      ts: Date.now(),
      kind: "session.error",
      payload: {
        message: "session is not live after a server restart — re-attach to continue",
      },
    });
  }

  /** A cold session has no turn to steer into (SPEC-mid-turn-steering-and-queue). */
  async steer(_input: UserInput): Promise<boolean> {
    return false;
  }

  async cancel(): Promise<void> {}

  /** Nothing to release: the agent process is already gone (SPEC-session-lifecycle-resume-list-delete). */
  async close(): Promise<void> {}

  async kill(): Promise<void> {
    this.emit("exit", null);
  }
}
