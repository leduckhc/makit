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
 * Thrown by {@link AgentAdapter.forkSession} when the back end cannot fork
 * because the thread has no persisted rollout yet — codex answers a
 * `thread/fork` on a thread that has never completed a turn with
 * `-32600 no rollout found for thread id <id>` (SPEC-cli-as-client U4). A distinct type so
 * `session.fork` can refuse this in plain words ("… has not run a turn yet")
 * instead of relaying the raw JSON-RPC string, and so a *real* transport bug
 * still surfaces as an unexpected error rather than a graceful refusal.
 */
export class ForkPreconditionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ForkPreconditionError";
  }
}

/**
 * Transport-neutral summary of ONE prior agent session/thread, produced by a
 * transport's native listing (ACP `session/list`, codex `thread/list`) and
 * normalized here so the manager can merge results across agents (SPEC-session-lifecycle-resume-list-delete).
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
   * codex `threadId`) after a server restart (SPEC-session-lifecycle-resume-list-delete). When set, `start()`
   * resumes that session instead of creating a fresh one — preferring a
   * no-replay resume (ACP `session/resume`, codex `thread/resume`) and falling
   * back to a silent replay-load (ACP `session/load`) or, if the agent can do
   * neither, a fresh session (degraded, but live).
   */
  resumeAgentSessionId?: string;
  /**
   * REQUEST a specific model — best-effort, not a guarantee. When unset the
   * agent keeps its own configured default; when the agent does not offer the
   * requested id it ALSO keeps its default (with a warning) rather than failing
   * to start. Callers that must not run on an unintended provider have to verify
   * the model after start (see test/fake-model/billing-guard.ts).
   *
   * Delivered per back end, NOT as a CLI flag: codex passes it on
   * `turn/start.model`; the ACP path applies it over the SPEC-acp-config-options-unified-composer config-option
   * surface (`pi-acp`'s argv is fixed, so `--model` never reaches pi). An agent
   * that does not offer the model stays on its default and logs a warning.
   */
  model?: string;
}

export interface UserInput {
  text: string;
  /**
   * Images the user attached (SPEC-user-attachments). Already resolved against the media
   * store by the `send.message` handler, so every entry has verified bytes on
   * disk. Absent when the turn is text-only; adapters that ignore the field
   * degrade to today's behaviour.
   */
  attachments?: MediaAttachment[];
}

/**
 * A back end's session-lifecycle capabilities (SPEC-session-lifecycle-resume-list-delete), negotiated per adapter
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
   *  Informational for now — makit's own `closed` flag drives the active-list
   *  exclusion; a native-archive path can consume this later. */
  archive: boolean;
  /**
   * Release a live session's resources WITHOUT destroying it (ACP
   * `session/close`, codex `thread/unsubscribe`). Distinct from `delete`: the
   * session stays listable and resumable afterwards. Drives the graceful step
   * of {@link AgentAdapter.close}.
   */
  close: boolean;
}

/** All-false capabilities — the safe default for a process-less adapter. */
export const NO_SESSION_CAPABILITIES: Readonly<SessionCapabilities> = Object.freeze({
  resume: false,
  load: false,
  list: false,
  delete: false,
  fork: false,
  archive: false,
  close: false,
});

export interface AgentAdapter extends EventEmitter {
  readonly agent: string;
  /**
   * The back end's session-lifecycle capabilities (SPEC-session-lifecycle-resume-list-delete). For ACP this is
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
   * (SPEC-mid-turn-steering-and-queue). Resolves `true` when the agent accepted it (and echoed the
   * `user.message` itself, as `send` does), `false` when this back end cannot
   * steer right now, in which case the caller queues the message until idle.
   *
   * Only codex has a real primitive for this (`turn/steer`); ACP has none in v1
   * or the v2 draft, so its adapter reports `false`. Never called while idle.
   */
  steer(input: UserInput): Promise<boolean>;
  /**
   * Optional: adapter-native fork of THIS session/thread at its head — a
   * high-fidelity branch of the same conversation (codex `thread/fork`; ACP
   * `session/fork` when it lands). Gated on {@link SessionCapabilities.fork};
   * an adapter that advertises `fork: false` omits it. Resolves the forked
   * thread's native id, which the caller adopts through the resume path so the
   * child continues the conversation rather than starting fresh (SPEC-cli-as-client U4).
   * Rejects with {@link ForkPreconditionError} when the back end has no rollout
   * to fork yet.
   */
  forkSession?(): Promise<{ agentSessionId: string }>;
  /**
   * Optional: run a built-in control action (e.g. `compact`, `thinking`) that
   * is NOT a user turn and never reaches the LLM as a prompt. Adapters that
   * can't map actions omit this.
   */
  sendAction?(action: string, args?: Record<string, unknown>): Promise<void>;
  cancel(): Promise<void>;
  /**
   * Ask the agent to release this session before its process is reaped (ACP
   * `session/close`, codex `thread/unsubscribe`). Per ACP this implies a cancel
   * of any in-flight turn, then frees the session's resources while leaving it
   * listable and resumable. A back end without the capability no-ops.
   *
   * MAY reject and MAY hang: this is the courtesy half of a teardown whose
   * second half ({@link kill}) is what actually reclaims memory.
   * `SessionManager.closeSession` is the single owner of that policy — it bounds
   * this call and swallows the outcome, then reaps regardless — so adapters
   * implement the plain request and nothing more.
   */
  close(): Promise<void>;
  kill(signal?: NodeJS.Signals): Promise<void>;

  on(event: "event", listener: (e: AdapterEvent) => void): this;
  on(event: "exit", listener: (code: number | null) => void): this;
  on(event: "status", listener: (status: "idle" | "running") => void): this;
  /** Agent-driven session rename (e.g. pi's `setTitle`). */
  on(event: "title", listener: (title: string) => void): this;
}
