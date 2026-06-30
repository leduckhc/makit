/**
 * AgentAdapter: the seam that every agent CLI plugs into. See
 * `docs/ARCHITECTURE.md` §5.
 */

import { EventEmitter } from "node:events";
import type { SessionEvent } from "../protocol.js";

/** Event payload from an adapter — server fills in seq + sessionId. */
export type AdapterEvent = Omit<SessionEvent, "seq" | "sessionId">;

export interface SpawnOpts {
  cwd: string;
  /** Optional initial system prompt or model overrides. */
  systemPrompt?: string;
}

export interface UserInput {
  text: string;
}

export interface AgentAdapter extends EventEmitter {
  readonly agent: string;
  start(opts: SpawnOpts): Promise<void>;
  send(input: UserInput): Promise<void>;
  cancel(): Promise<void>;
  kill(signal?: NodeJS.Signals): Promise<void>;

  on(event: "event", listener: (e: AdapterEvent) => void): this;
  on(event: "exit", listener: (code: number | null) => void): this;
  on(event: "status", listener: (status: "idle" | "running") => void): this;
}
