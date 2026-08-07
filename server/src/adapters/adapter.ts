/**
 * AgentAdapter: the seam that every agent CLI plugs into. See
 * `docs/ARCHITECTURE.md` §5.
 */

import { EventEmitter } from "node:events";
import type { MediaAttachment } from "../media/store.js";
import type { SessionEvent } from "../protocol.js";
import type { AskUser } from "../uicall.js";

/** Event payload from an adapter — server fills in seq + sessionId. */
export type AdapterEvent = Omit<SessionEvent, "seq" | "sessionId">;

/**
 * Transport-neutral summary of ONE prior agent session/thread, produced by a
 * transport's native listing (ACP `session/list`, codex `thread/list`) and
 * normalized here so the manager can merge results across agents (SPEC-29).
 */
export interface AgentSessionInfo {
  /** Native session/thread id (ACP sessionId, codex threadId). */
  id: string;
  /** Working directory the session ran in. */
  cwd: string;
  /** Human title, when the agent supplies one. */
  title?: string;
  /** Short preview of the first/last message, when available. */
  preview?: string;
  /** Count of messages, when the agent reports it. */
  messageCount?: number;
  /** Last-activity timestamp in epoch ms. */
  updatedAt?: number;
}

export interface SpawnOpts {
  cwd: string;
  /** Optional initial system prompt or model overrides. */
  systemPrompt?: string;
  /** Extra env vars for the spawned process (e.g. MAKIT_BRIDGE_*). */
  env?: Record<string, string>;
  /**
   * Paths to pi extensions to load.
   *
   * NOT honoured on the ACP path: pi runs behind the `pi-acp` bridge, which
   * spawns pi with a fixed argv (`--mode rpc --no-themes` [+ `--session`]) and
   * forwards no `-e`. {@link AcpAdapter} warns and ignores them rather than
   * pretending. Loading an extension per session needs a pi-acp change.
   */
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
   * @deprecated Legacy native-pi path; superseded by {@link resumeAgentSessionId}.
   */
  resumeSessionPath?: string;
  /**
   * Resume/load an existing agent session by its NATIVE id (ACP `sessionId`,
   * codex `threadId`) after a server restart (SPEC-29). When set, `start()`
   * resumes that session instead of creating a fresh one — preferring a
   * no-replay resume (ACP `session/resume`, codex `thread/resume`) and falling
   * back to a silent replay-load (ACP `session/load`) or, if the agent can do
   * neither, a fresh session (degraded, but live).
   */
  resumeAgentSessionId?: string;
  /**
   * Force a specific model. When unset the agent keeps its own configured
   * default.
   *
   * Delivered per back end, NOT as a CLI flag: codex passes it on
   * `turn/start.model`; the ACP path applies it over the SPEC-26 config-option
   * surface (`pi-acp`'s argv is fixed, so `--model` never reaches pi). An agent
   * that does not offer the model stays on its default and logs a warning.
   */
  model?: string;
}

export interface UserInput {
  text: string;
  /**
   * Images the user attached (SPEC-33). Already resolved against the media
   * store by the `send.message` handler, so every entry has verified bytes on
   * disk. Absent when the turn is text-only; adapters that ignore the field
   * degrade to today's behaviour.
   */
  attachments?: MediaAttachment[];
}

/**
 * A back end's session-lifecycle capabilities (SPEC-29), negotiated per adapter
 * (ACP: from the `initialize` response; codex: static for the supported
 * app-server). Every field defaults to `false` so an adapter that reports
 * nothing degrades to today's history-only behaviour.
 */
export interface SessionCapabilities {
  /** Native resume WITHOUT replay (ACP `session/resume`, codex `thread/resume`). */
  resume: boolean;
  /** Replay-based load (ACP `session/load`) — used when `resume` is unavailable. */
  load: boolean;
  /** Enumerate prior sessions (ACP `session/list`, codex `thread/list`). */
  list: boolean;
  /** Delete a session/thread (ACP `session/delete`, codex `thread/delete`). */
  delete: boolean;
  /** Fork a session/thread (codex `thread/fork`; ACP `session/fork` when added). */
  fork: boolean;
  /** Archive/unarchive capability on the back end (codex `thread/archive`).
   *  Informational for now — makit's own `archived` flag drives the active-list
   *  exclusion; a native-archive path can consume this later. */
  archive: boolean;
}

/** All-false capabilities — the safe default for a process-less adapter. */
export const NO_SESSION_CAPABILITIES: Readonly<SessionCapabilities> = Object.freeze({
  resume: false,
  load: false,
  list: false,
  delete: false,
  fork: false,
  archive: false,
});

export interface AgentAdapter extends EventEmitter {
  readonly agent: string;
  /**
   * The back end's session-lifecycle capabilities (SPEC-29). For ACP this is
   * only authoritative AFTER `start()` (it is read from the `initialize`
   * response); codex reports it statically. Defaults to all-false.
   */
  readonly capabilities: SessionCapabilities;
  /**
   * The native session/thread id once `start()` has resolved (ACP `sessionId`,
   * codex `threadId`). Undefined before start and for the detached adapter.
   * Persisted so the session can be resumed after a server restart.
   */
  readonly agentSessionId?: string;
  start(opts: SpawnOpts): Promise<void>;
  send(input: UserInput): Promise<void>;
  /**
   * Inject `input` into the turn that is ALREADY running — "steering"
   * (SPEC-35). Resolves `true` when the agent accepted it (and echoed the
   * `user.message` itself, as `send` does), `false` when this back end cannot
   * steer right now, in which case the caller queues the message until idle.
   *
   * Only codex has a real primitive for this (`turn/steer`); ACP has none in v1
   * or the v2 draft, so its adapter reports `false`. Never called while idle.
   */
  steer(input: UserInput): Promise<boolean>;
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
