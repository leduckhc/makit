/**
 * Wire protocol — keep in sync with `app/lib/transport/protocol.dart`.
 *
 * Single source of truth would be a shared JSON schema; for M0 we mirror by
 * hand and trust the test surface to catch drift.
 */

export const PROTOCOL_VERSION = 1;

/** Default title for a freshly-spawned, not-yet-named session. */
export const DEFAULT_SESSION_TITLE = "new session";

export type MsgType =
  | "hello"
  | "hello.ack"
  | "sub"
  | "unsub"
  | "event"
  | "cmd"
  | "ack"
  | "err"
  | "presence"
  | "ping"
  | "pong"
  | "srv.request"    // server → app: ask the user something (id correlates)
  | "srv.response"; // app → server: answer to a previous srv.request

export interface Envelope {
  v: number;
  t: MsgType;
  id: string;
  [k: string]: unknown;
}

export type EventKind =
  | "user.message"
  | "agent.message"
  | "agent.message.delta"
  | "agent.thinking"
  | "agent.thinking.delta"
  | "tool.call.start"
  | "tool.call.delta"
  | "tool.call.end"
  | "session.status"
  | "session.error"
  | "session.commands"
  | "session.meta"
  // NOTE (SPEC-18 T5): `session.action_error` is KEPT, not deleted. Although
  // the server does not yet EMIT it, it is a fully-wired app consumer (an
  // `ActionError` model + store reducer surface it as a snackbar in
  // session_screen.dart / desktop_chat_pane.dart). Deleting it would strand a
  // live consumer; wiring the producer belongs in the `session.action`/`cancel`
  // handlers (server.ts) / session.ts, which are out of this spec's scope.
  | "session.action_error";

export interface SessionEvent {
  seq: number;
  sessionId: string;
  ts: number;
  kind: EventKind;
  payload: Record<string, unknown>;
}

export type SessionStatus =
  | "idle"
  | "running"
  | "awaiting-input"
  | "awaiting-approval"
  | "error"
  | "exited";

export type ApprovalPolicy = "yolo" | "ask-on-risky" | "ask-always";

export interface ProjectDTO {
  id: string;
  name: string;
  path: string;
  pinned: boolean;
  lastActivityAt: number;
}

/** Open pull request tied to a worktree's branch (via `gh`). */
export interface PullRequestDTO {
  number: number;
  url: string;
  state: string;
  title: string;
  isDraft: boolean;
}

/**
 * A git worktree of a repo. `isPrimary` marks the repo's main checkout. Diff
 * stats are measured against the repo's default branch; `pr` is present only
 * when an open GitHub PR heads this branch. `sessionIds` links the makit
 * sessions currently running in this worktree.
 */
export interface WorktreeDTO {
  id: string;
  path: string;
  branch: string | null;
  isPrimary: boolean;
  insertions: number;
  deletions: number;
  filesChanged: number;
  /** HEAD commit time in epoch milliseconds, or null when unavailable. */
  committedAt: number | null;
  pr: PullRequestDTO | null;
  sessionIds: string[];
}

/**
 * Repo-centric home-screen unit. Wraps a {@link ProjectDTO} with git
 * intelligence: the current + default branch and the list of live worktrees.
 */
export interface RepoDTO {
  id: string;
  name: string;
  path: string;
  pinned: boolean;
  lastActivityAt: number;
  isGitRepo: boolean;
  defaultBranch: string | null;
  currentBranch: string | null;
  worktrees: WorktreeDTO[];
}

export interface SessionDTO {
  id: string;
  projectId: string;
  agent: string;
  title: string;
  status: SessionStatus;
  policy: ApprovalPolicy;
  lastActivityAt: number;
  lastPreview: string;
  /**
   * Draft state: a spawned session whose worktree + agent are deferred until
   * the first substantive user message (which names the branch/worktree).
   */
  pending: boolean;
  /** Chosen harness for a still-pending draft (before its worktree exists). */
  pendingAgent?: string;
  /** Branch this session runs on, once its worktree exists. */
  branch?: string;
  /** Absolute worktree path, once created. */
  worktreePath?: string;
}

let _seq = 0;
export const newId = (prefix = "id") => `${prefix}-${Date.now().toString(36)}-${(_seq++).toString(36)}`;

/**
 * `cmd` kinds. This union mirrors the handlers actually registered by
 * `buildCommandRouter` in `server.ts` (+ `push.register` in
 * `push/register_cmd.ts`) — it is documentation only (the router keys off raw
 * strings), so it is kept in lockstep with the registry by hand and the test
 * surface. Previously it had drifted: it listed `session.policy` (no handler)
 * and omitted `session.action`, `session.setAgent`, `worktree.create`,
 * `session.list`, `project.*`, and `debug.*`.
 *
 * SPEC-07: `push.register` — the phone registers its content-free wake push
 * token: `cmd {kind:'push.register', token, platform, env?}`. The server
 * persists it per-device in `~/.makit/devices.json` so the WakeCoordinator can
 * wake a force-quit/suspended device. The payload NEVER carries session data.
 */
export type CmdKind =
  // session lifecycle + turns
  | "send.message"
  | "session.action"
  | "cancel"
  | "session.spawn"
  | "session.list"
  | "session.attach"
  | "session.kill"
  | "session.setAgent"
  // repos / projects / worktrees
  | "worktree.create"
  | "repo.refresh"
  | "project.browse"
  | "project.add"
  | "project.remove"
  // misc
  | "agents.list"
  | "push.register"
  // dev-only probes
  | "debug.ask"
  | "debug.ask-multi";
