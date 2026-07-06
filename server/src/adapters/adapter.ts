/**
 * AgentAdapter: the seam that every agent CLI plugs into. See
 * `docs/ARCHITECTURE.md` §5.
 */

import { EventEmitter } from "node:events";
import type { SessionEvent } from "../protocol.js";
import type { AskUser } from "../uicall.js";

/** Event payload from an adapter — server fills in seq + sessionId. */
export type AdapterEvent = Omit<SessionEvent, "seq" | "sessionId">;

export interface SpawnOpts {
  cwd: string;
  /** Optional initial system prompt or model overrides. */
  systemPrompt?: string;
  /** Extra env vars for the spawned process (e.g. PINO_BRIDGE_*). */
  env?: Record<string, string>;
  /** Paths to pi extensions to load via `-e`. */
  extensions?: string[];
  /** Session id used for routing reverse-RPC. */
  /** Session id used for routing reverse-RPC. */
  sessionId?: string;
  /**
   * Present a UICall on the user's phone and resolve with their answer. When
   * set, the adapter transports the agent's UI requests (e.g. pi's
   * ctx.ui.select/confirm/input) to the app instead of failing headless.
   */
  askUser?: AskUser;
  /**
   * Resume an existing pi session from its on-disk transcript. When set, pi is
   * launched with `--session <path>` instead of a fresh `--session-id`.
   */
  resumeSessionPath?: string;
}

export interface UserInput {
  text: string;
}

export interface AgentAdapter extends EventEmitter {
  readonly agent: string;
  start(opts: SpawnOpts): Promise<void>;
  send(input: UserInput): Promise<void>;
  /**
   * Optional: run a built-in control action (e.g. `compact`, `thinking`) that
   * is NOT a user turn and never reaches the LLM as a prompt. Adapters that
   * can't map actions omit this.
   */
  sendAction?(action: string, args?: Record<string, unknown>): Promise<void>;
  cancel(): Promise<void>;
  kill(signal?: NodeJS.Signals): Promise<void>;

  on(event: "event", listener: (e: AdapterEvent) => void): this;
  on(event: "exit", listener: (code: number | null) => void): this;
  on(event: "status", listener: (status: "idle" | "running") => void): this;
  /** Agent-driven session rename (e.g. pi's `setTitle`). */
  on(event: "title", listener: (title: string) => void): this;
}
