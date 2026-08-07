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
  /**
   * Context-window + cost snapshot for this session (SPEC-37). Latest-wins:
   * every update carries the whole picture, so the app keeps only the newest
   * and replay needs no folding. See {@link SessionUsageDTO}.
   */
  | "session.usage"
  /** GitHub API budget snapshot (SPEC-32 §6.6) — a top-level broadcast event. */
  | "github.budget"
  /**
   * Host-wide performance sample (SPEC-37). Like {@link github.budget}, this is
   * a top-level broadcast event, NOT a session event: metrics describe the whole
   * makit host (server, app, every agent tree), not one session, and they must
   * **never** enter the append-only session log (spec decision 5). Writing them
   * there would bloat every session's transcript and slow every resume forever,
   * for data that is inherently ephemeral. Do not "tidy" it into `SessionEvent`.
   */
  | "metrics.sample"
  /**
   * Every listening TCP port on the host, attributed to the worktree that owns
   * it (SPEC-41). Like {@link github.budget} and {@link metrics.sample} this is a
   * top-level broadcast, NOT a session event: ports describe the machine, not one
   * session, and a 4-second snapshot must never enter the append-only session log.
   * Watch-gated — nothing is scanned or sent unless a client asked via
   * `ports.watch`. See {@link PortsSnapshotDTO}.
   */
  | "ports.snapshot";

/**
 * Normalized context/cost usage for one session (SPEC-37), unified across three
 * sources that each report a different subset:
 *
 * - **codex** `thread/tokenUsage/updated` — full token breakdown + window, no cost.
 * - **ACP** `usage_update` — `used`/`size`/`cost` only, no breakdown.
 * - **pi** via the `makit-pi-usage` extension over the loopback bridge — pi
 *   reports nothing over ACP, so the extension reads the numbers in-process.
 *
 * Hence every field but `measuredAt` is optional, and **absent is not zero**: a
 * field we never measured must render as unknown, never as `0` (the same rule
 * {@link GithubBucketDTO} follows — a zeroed bar and an unknown bar mean
 * opposite things).
 */
export interface SessionUsageDTO {
  /**
   * Tokens currently occupying the context window — what to draw against
   * {@link contextWindow}.
   *
   * NOTE for codex: this is the LAST request's total, never the session total.
   * The last request's input already contains the whole conversation plus the
   * system prompt and tool definitions, whereas the session total accumulates
   * across turns and would cross 100% of the window on a long session that
   * never came close to compaction.
   */
  contextTokens?: number;
  /** Context window size in tokens, when the agent reports one. */
  contextWindow?: number;
  /**
   * Cumulative session totals — **billing**, not context occupancy. Deliberately
   * kept apart from {@link contextTokens} so the two can never be drawn against
   * the same bar.
   */
  totals?: SessionUsageTotals;
  /** Cumulative session cost, when the agent prices its own calls. */
  cost?: { amount: number; currency: string };
  /** Epoch ms this snapshot was measured. */
  measuredAt: number;
}

/** Cumulative per-category token counts for a session (SPEC-37). */
export interface SessionUsageTotals {
  total?: number;
  input?: number;
  /** Input tokens served from the provider's prompt cache. */
  cachedInput?: number;
  /** Input tokens written INTO the cache. */
  cacheWrite?: number;
  output?: number;
  /** Reasoning/thinking output tokens, when billed separately. */
  reasoning?: number;
}

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

// ---------------------------------------------------------------------------
// SPEC-37 metrics DTOs — the wire contract for the `metrics.sample` event.
//
// These live here, next to `github.budget`, because this is where the wire
// contract lives; `metrics/collector.ts` imports them rather than duplicating
// the shapes. They are deliberately NOT part of `SessionEvent`: a metrics sample
// is a host-wide broadcast that must stay out of the append-only session log
// (spec decision 5) — see the `metrics.sample` note on {@link EventKind}.
// ---------------------------------------------------------------------------

/** One measured surface (the app, the server, or an agent tree). */
export interface SurfaceDTO {
  pid: number;
  rssBytes: number;
  /** `null` — never `0` — until a rate is computable (spec decision 2). */
  cpuPercent: number | null;
  cpuSeconds: number;
}

export interface AgentMetricsDTO extends SurfaceDTO {
  sessionId: string;
  label: string;
  inTurn: boolean;
  /** Omitted on coarse (idle-cadence) frames — they only colour an icon. */
  procs?: number;
  /** Omitted on coarse (idle-cadence) frames. */
  uptimeMs?: number;
}

/**
 * One performance sample, carried on the `metrics.sample` event as
 * `{ sample: MetricsSampleDTO; history?: MetricsSampleDTO[] }`. `history` is
 * present ONLY on the first frame after `metrics.watch {on:true}`.
 */
export interface MetricsSampleDTO {
  ts: number;
  app: SurfaceDTO | null;
  server: SurfaceDTO & { eventLoop: { p50: number; p99: number } };
  agents: AgentMetricsDTO[];
  wire: { inBytesPerSec: number; outBytesPerSec: number; framesPerSec: number };
  storage: { eventLogBytes: number } | null;
  /**
   * SPEC-37 decision 10 + 16 — what the measurement itself costs.
   *
   * `cpuPercent` is the CPU the tick burned over the *interval between* ticks
   * (null until a second tick gives an interval). `rssBytes` is **null**: the
   * sampler lives inside the server process, so its resident share is not
   * separately attributable, and reporting `process.memoryUsage().rss` here
   * merely restated the `server` row above under an "own cost" label.
   */
  sampler: { cpuPercent: number | null; rssBytes: number | null };
  turnActive: boolean;
  /**
   * False when `ps` could not be read this tick, in which case `agents` is empty
   * and `app` is null **because we could not look** — not because they exited.
   */
  procTableOk: boolean;
}

// SPEC-41 ports DTOs — the wire contract for the `ports.snapshot` event.
//
// Every optional field means "not known", never "zero": a port whose `health` is
// absent was not probed, and a port with no `worktreePath` is genuinely unowned.
// The app renders absence as absence (the rule `BudgetBucket` and
// `SessionUsageDTO` already follow).

/** Where a listening socket can be reached from (spec D2). Derived, not reported. */
export type PortReach =
  /** 127.0.0.0/8 or ::1 — this machine only. */
  | "loopback"
  /** Bound to EXACTLY the host's discovered tailnet address. */
  | "tailnet"
  /**
   * Any other address, including a wildcard bind. A `0.0.0.0` listener is
   * reachable from every interface, so it is never reported as `tailnet` —
   * that would be the reassuring reading of an alarming fact.
   */
  | "exposed";

/** Verdict from one HTTP probe. No health at all means "not probed" (spec D3). */
export type PortHealthKind = "ok" | "http-error" | "refused" | "timeout";

export interface PortHealthDTO {
  kind: PortHealthKind;
  /** HTTP status when one was parsed (200, 404, 500); absent otherwise. */
  status?: number;
  /** Epoch ms of the probe that produced this verdict — drives "probed Ns ago". */
  probedAt: number;
}

/** One listening TCP socket, with whatever makit could truthfully learn about it. */
export interface PortDTO {
  /**
   * Snapshot key, NOT a durable identity (spec D6): `<pid>:<address>:<port>`.
   * PIDs are reused and a restart changes the PID for the same endpoint, so this
   * must never be persisted — the app re-selects by `(address, port)`.
   */
  key: string;
  port: number;
  /** Bind address as reported: `127.0.0.1`, `0.0.0.0`, `*`, `::1`, `::`. */
  address: string;
  reach: PortReach;
  pid: number;
  /** Full argv, trimmed. */
  command: string;
  /** Epoch ms the process started; absent when the elapsed time was unparsable. */
  startedAt?: number;
  /** Absolute worktree path that owns this port; absent when unowned. */
  worktreePath?: string;
  /** Session whose process tree contains {@link pid}, when there is one. */
  sessionId?: string;
  /** Absent until probed, and absent forever for ports makit does not probe. */
  health?: PortHealthDTO;
  /**
   * Canonical URL to open, present only when something actually answered HTTP.
   * Built server-side so the two clients cannot disagree, and absent rather than
   * guessed — a wildcard bind has no usable host and IPv6 needs brackets:
   *   loopback / wildcard IPv4 -> `http://127.0.0.1:<port>`
   *   `::1` / `::`             -> `http://[::1]:<port>`
   *   a concrete address       -> `http://<address>:<port>`
   * Absent means the UI hides Open/Copy rather than offering a broken link.
   */
  openUrl?: string;
  /**
   * SPEC-42 D10. Present only when this listener's cwd matches a worktree that
   * history records as REMOVED — i.e. nothing will ever reclaim the port but the
   * user. Mutually exclusive with {@link worktreePath}: an orphan is by
   * definition unowned. Absent for every port makit cannot prove is orphaned,
   * including on a first run with no history — the fields inside are individually
   * optional so a known-orphan with an unknown date never fabricates one.
   */
  orphan?: PortOrphanDTO;
  /**
   * SPEC-42 D12. Present when history shows a second ACTIVE worktree also claims
   * this port, so a dev server started there would fail to bind. Derived from
   * history, not from the live scan: the OS forbids two live LISTENs on one
   * endpoint, so the rival is by construction not currently running.
   */
  collision?: PortCollisionDTO;
}

/**
 * Why a listener is an orphan. Every field is optional on purpose (SPEC-41's
 * absent-stays-absent rule): makit can often prove the cwd is a dead worktree
 * while knowing neither its branch nor when it was removed, and a fabricated
 * "removed 0d ago" would be worse than silence.
 */
export interface PortOrphanDTO {
  /** Branch the removed worktree was on, when history recorded it. */
  formerBranch?: string;
  /** Absolute path of the worktree that is gone. */
  formerWorktreePath?: string;
  /** Epoch ms makit first saw the worktree missing; absent when unknown. */
  removedAt?: number;
}

/** The rival claimant for a port. */
export interface PortCollisionDTO {
  /** Branch of the other worktree that history says also uses this port. */
  withBranch?: string;
  /** Absolute path of that worktree. */
  withWorktreePath?: string;
}

/** One host-wide scan, carried on the `ports.snapshot` event as `snapshot`. */
export interface PortsSnapshotDTO {
  /** Listening TCP ports, ascending by port then pid. */
  ports: PortDTO[];
  /** Epoch ms this scan completed. */
  scannedAt: number;
  /**
   * True when the scanner's commands ran (spec D7). It does NOT claim the whole
   * machine was visible: `lsof` exits 0 while omitting processes owned by other
   * users or shielded by OS privacy policy, so attribution is best-effort.
   */
  scanOk: boolean;
  /** One-line reason when `scanOk` is false — rendered in the glyph's tooltip. */
  scanError?: string;
}

/**
 * The kinds that may appear **inside a session's event log**.
 *
 * `github.budget`, `metrics.sample` and `ports.snapshot` are host-wide broadcasts,
 * not session events: the log is append-only and replayed in full on every resume,
 * so a per-second metrics row would grow it without bound and slow every resume.
 * Excluding them here makes that a **compile-time** boundary instead of a comment
 * a future contributor can miss (review finding).
 */
export type SessionEventKind = Exclude<
  EventKind,
  "github.budget" | "metrics.sample" | "ports.snapshot"
>;

export interface SessionEvent {
  seq: number;
  sessionId: string;
  ts: number;
  kind: SessionEventKind;
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
  /**
   * Branch the PR merges into. The app's "wrap up" fast-forwards this one after
   * the PR lands. Optional so an app talking to an older server still decodes;
   * when it is missing the server falls back to the repo's default branch.
   */
  baseRefName?: string | null;
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
  /** Interrupt the turn so ONE pending message is delivered next (SPEC-39). */
  | "queue.promote"
  // repos / projects / worktrees
  | "worktree.create"
  | "worktree.createFromPr"
  | "worktree.remove"
  | "worktree.wrapUp"
  | "worktree.discard"
  | "pr.markReady"
  | "pr.updateBranch"
  | "pr.squashMerge"
  | "branch.rename"
  | "pr.list"
  | "repo.refresh"
  | "project.browse"
  | "project.add"
  | "project.remove"
  // misc
  | "agents.list"
  | "agents.refresh"
  /**
   * SPEC-41: hold/release the host-wide port scan. `{kind:'ports.watch', on}` —
   * nothing is scanned while no client is watching.
   */
  | "ports.watch"
  | "push.register"
  | "client.log"
  // dev-only probes
  | "debug.ask"
  | "debug.ask-multi";
