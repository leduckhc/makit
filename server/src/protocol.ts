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
  /**
   * The user's own turn, echoed by the adapter so transcripts are complete.
   * `payload.text` is the prompt; `payload.attachments` (SPEC-33) is an optional
   * array of **resolved** `MediaAttachment` descriptors
   * (`{mediaId, mime, sizeBytes, name?}`) for images the user attached — richer
   * than the inbound {@link WireAttachment}, which carries only an id + name. As with
   * `agent.media`, only the descriptor is carried — the app fetches bytes from
   * `GET /media/<mediaId>` — because the event log is replayed in full on resume.
   *
   * `payload.steered === true` (SPEC-35) marks a message that was injected into
   * the turn that was ALREADY running instead of starting a new one. Present only
   * on the transports that can do it (codex `turn/steer`); the app captions the
   * bubble with it, which is the only way the user learns the difference between
   * steering and queueing from their own transcript.
   */
  | "user.message"
  | "agent.message"
  | "agent.message.delta"
  /**
   * Assistant display media (SPEC-22): an image/GIF the agent produced or
   * referenced. Carries only a descriptor — the bytes are fetched from
   * `GET /media/<mediaId>`, never inlined, because the event log is replayed
   * in full on every resume.
   */
  | "agent.media"
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
  | "session.action_error"
  /** GitHub API budget snapshot (SPEC-32 §6.6) — a top-level broadcast event. */
  | "github.budget";

/**
 * GitHub API budget broadcast (SPEC-32 §6.6). Sent as a top-level
 * `event {kind:"github.budget", budget}` frame (not a session event) on a
 * budget level/throttle change and in the connect snapshot. `resetAt`/
 * `measuredAt` are epoch **ms**; `history` is 60 per-minute slots, oldest first.
 */
export interface GithubBucketDTO {
  limit: number;
  remaining: number;
  /** Epoch ms when the window resets. */
  resetAt: number;
  /** Requests attributed to makit in this window. */
  mine: number;
  /** Spend by other tools sharing the token (derived). */
  others: number;
}

export interface GithubBudgetDTO {
  buckets: {
    core: GithubBucketDTO | null;
    graphql: GithubBucketDTO | null;
    search: GithubBucketDTO | null;
  };
  burnPerHour: number;
  msUntilEmpty: number | null;
  level: "healthy" | "warm" | "critical" | "paused" | "unknown";
  throttles: string[];
  retryAfterMs: number | null;
  measuredAt: number;
  /** 60 per-minute `{mine, others}` slots, oldest first (sparkline source). */
  history: Array<{ mine: number; others: number }>;
  /** Exec vs. cache-hit counters (verifies the ≥80% call-reduction claim). */
  stats: { execs: number; cacheHits: number };
}

export interface SessionEvent {
  seq: number;
  sessionId: string;
  ts: number;
  kind: EventKind;
  payload: Record<string, unknown>;
}

/**
 * One attachment as it arrives on `send.message` (SPEC-33).
 *
 * Deliberately just an id plus a display hint: the bytes were already uploaded
 * to the content-addressed store via `POST /media`, so the id is sufficient and
 * self-verifying. `name` is a **hint only** — it is never used as a path. When a
 * file has to be materialised for the agent, the server derives the on-disk name
 * from the content hash and sanitises the hint (see `media/attach.ts`).
 */
export interface WireAttachment {
  mediaId: string;
  name?: string;
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

/**
 * One message waiting to be delivered when the agent next goes idle (SPEC-35).
 * Attachments are reported as a count, not as descriptors: the chip only needs
 * to say "and an image", and the bytes are already safe in the media store.
 */
export interface QueuedMessageDTO {
  /** Stable for the lifetime of the queue entry; the handle `queue.cancel` takes. */
  id: string;
  text: string;
  queuedAt: number;
  attachmentCount?: number;
}

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
  /** True when this PR was not re-fetched successfully; the UI shows it dimmed. */
  stale?: boolean;
  /** True when unresolvedComments was shed to save quota (the value is not reliable). */
  unresolvedUnknown?: boolean;
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
   * Messages the user submitted while the agent was busy that this back end
   * could not steer into the running turn (SPEC-35), oldest first. They are
   * delivered one per idle transition and are NOT in the event log until then,
   * so a cancelled one leaves no transcript trace. Carried on the DTO rather
   * than as an event kind precisely because it is live state: it must not
   * survive a restart as a ghost queue in a replayed log.
   */
  queued: QueuedMessageDTO[];
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
  /**
   * True when this session can be brought back to a live agent after a server
   * restart — it has a persisted native session/thread id and its back end
   * supports resume/load (SPEC-29). Cold resumable sessions are auto-attached
   * by the app on subscribe; non-resumable cold sessions stay read-only.
   */
  resumable: boolean;
  /**
   * Archived (SPEC-29): a soft, recoverable hide. Archived sessions are omitted
   * from the active `sessions.snapshot`; this flag is present for any surface
   * that explicitly lists archived sessions.
   */
  archived: boolean;
  /**
   * Orphaned (SPEC-29): an archived session whose recorded worktree is no longer
   * an active worktree of its project (e.g. the worktree was removed). Only set
   * on the `session.listArchived` result; undefined elsewhere. The branch ref
   * usually still exists, so resume can offer to recreate the worktree.
   */
  orphaned?: boolean;
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
  | "session.archive"
  | "session.unarchive"
  | "session.listArchived"
  | "session.setAgent"
  /** Drop ONE pending mid-turn message by `queuedId` (SPEC-35). */
  | "queue.cancel"
  /** Edit a pending mid-turn message; empty text cancels it (SPEC-38). */
  | "queue.update"
  /** Reorder the pending messages; `ids` is a hint, not an assertion (SPEC-38). */
  | "queue.reorder"
  /** Interrupt the turn so ONE pending message is delivered next (SPEC-37). */
  | "queue.promote"
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
  | "client.log"
  // dev-only probes
  | "debug.ask"
  | "debug.ask-multi";
