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

/**
 * Generic, category-tagged session config model (SPEC-26). Mirrors ACP v1's
 * Session Config Options and the codex app-server projection: the composer
 * renders this ONE list (ordered by agent priority) instead of the bespoke
 * model/thinking/mode widgets. Carried on `session.meta` as `configOptions`,
 * ADDITIVE alongside the legacy `{model, thinking, models, modes}` fields during
 * the migration window. Set via the `session.action` `configOption {id, value}`.
 */
export type ConfigOptionCategory = "mode" | "model" | "model_config" | "thought_level" | string;
export interface ConfigOptionValue {
  value: string;
  name: string;
  description?: string;
}
export interface ConfigOptionGroup {
  name: string;
  options: ConfigOptionValue[];
}
export interface SessionConfigOption {
  id: string;
  name: string;
  description?: string;
  category?: ConfigOptionCategory;
  type: "select" | "boolean";
  currentValue: string | boolean;
  // select only: either a flat value list OR named groups (ACP allows both).
  options?: ConfigOptionValue[];
  groups?: ConfigOptionGroup[];
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

/**
 * One CI check on a PR head, normalized from `gh`'s `statusCheckRollup` (which
 * mixes GitHub Actions `CheckRun` and legacy `StatusContext` shapes) into a
 * single flat form the app renders without any provider-shape logic.
 */
export type PrCheckBucket = "pass" | "fail" | "pending" | "skipping" | "cancel";
export interface PrCheckDTO {
  /** The check/context name, e.g. `test` or `CodeRabbit`. */
  name: string;
  bucket: PrCheckBucket;
  /** Owning workflow (Actions checks) or null for a legacy status context. */
  workflowName: string | null;
  /** Deep link to the check's details, or null when the provider gave none. */
  detailsUrl: string | null;
}

/** Aggregate CI verdict across a PR's checks (drives the pill tint). */
export type PrCheckRollup = "pass" | "fail" | "pending" | "none";

/** Open pull request tied to a worktree's branch (via `gh`). */
export interface PullRequestDTO {
  number: number;
  url: string;
  state: string;
  title: string;
  isDraft: boolean;
  /** MERGEABLE | CONFLICTING | UNKNOWN, or null when `gh` didn't report it. */
  mergeable: string | null;
  /** CLEAN | BLOCKED | BEHIND | DIRTY | …, or null when unreported. */
  mergeStateStatus: string | null;
  /** Per-check status for the hover popover. Empty when there are no checks. */
  checks: PrCheckDTO[];
  /** Aggregate CI verdict computed from {@link checks}. */
  checkRollup: PrCheckRollup;
  /** Count of unresolved review threads on the PR. */
  unresolvedComments: number;
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
  /** Files with uncommitted changes (staged + unstaged + untracked). */
  uncommittedFiles: number;
  /** Commits not yet pushed to the remote (what a push would send). */
  aheadCount: number;
  /** Commits on the upstream not yet local (what a pull would fetch). */
  behindCount: number;
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
  | "session.spawnLinked"
  | "session.list"
  | "session.attach"
  | "session.kill"
  | "session.setAgent"
  // repos / projects / worktrees
  | "worktree.create"
  | "worktree.createFromPr"
  | "worktree.remove"
  | "branch.rename"
  | "pr.list"
  | "repo.refresh"
  | "project.browse"
  | "project.add"
  | "project.remove"
  // misc
  | "agents.list"
  | "agents.refresh"
  | "push.register"
  // dev-only probes
  | "debug.ask"
  | "debug.ask-multi";
