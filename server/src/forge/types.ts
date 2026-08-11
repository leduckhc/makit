/**
 * types.ts — the provider-neutral forge contract.
 *
 * Split into two interfaces on purpose (interface segregation). Everything the
 * app actually needs from a forge — "is there a PR on this branch", "list open
 * PRs", "run this PR action" — is in {@link ForgeGateway}. The quota accounting
 * in {@link BudgetReporting} is a GitHub-only concern: self-hosted Forgejo
 * exposes no `rate_limit` endpoint and sends no rate-limit response headers, so
 * there is nothing for it to report.
 *
 * Keeping them separate is what stops a Forgejo provider from having to fake a
 * budget it cannot measure. A stub returning "unlimited" would be a lie the
 * footer would render as fact, and a stub throwing would turn a UI affordance
 * into a crash — {@link hasBudgetReporting} lets the caller ask instead.
 */

import type { OpenPr, PullRequestInfo } from "../git.js";

/** Three-way PR lookup result — a failed lookup is never `none` (SPEC-32 §6.5). */
export type PrLookup =
  | { kind: "pr"; pr: PullRequestInfo }
  | { kind: "none" }
  | { kind: "unknown"; reason: "throttled" | "error" };

/** A state-changing PR action the app can run on the user's behalf. */
export type PrMutation = "ready" | "update-branch" | "merge-squash";

/** Call/cache counters — how the ≥80% call-reduction claim is measured. */
export interface GatewayStats {
  /** Provider calls that spent quota (GitHub) or hit the network (Forgejo). */
  execs: number;
  /** Quota-exempt reads. Free, but still round trips. */
  exemptExecs: number;
  /** Reads served from cache without a round trip. */
  cacheHits: number;
}

/**
 * The forge operations the app depends on. Implemented by both providers —
 * `gh`-backed for GitHub, REST-backed for Forgejo.
 */
export interface ForgeGateway {
  /**
   * The latest PR whose head is `branch`, or `none` when there is genuinely no
   * PR. A lookup that could not be completed returns `unknown`, never `none`:
   * reporting "no PR" for a failed call erases the pill and reads as fact.
   */
  prForBranch(repoPath: string, branch: string, opts?: { interactive?: boolean }): Promise<PrLookup>;
  /**
   * All open PRs for a repo (the "New worktree from PR" picker).
   *
   * `interactive: true` marks a user-initiated call — a click, not a poll — so a
   * provider that sheds load must still serve it rather than return an empty
   * list the user would read as "this repo has no open PRs".
   */
  openPrs(repoPath: string, limit: number, opts?: { interactive?: boolean }): Promise<OpenPr[]>;
  /**
   * Run a state-changing PR verb. Always interactive (a button press), and must
   * invalidate any cached lookup for `branch` on success — otherwise the UI keeps
   * reporting the state the mutation just changed until the TTL expires.
   */
  mutatePr(
    repoPath: string,
    branch: string,
    number: number,
    verb: PrMutation,
  ): Promise<{ ok: boolean; error?: string }>;
  stats(): GatewayStats;
  close(): void;
}

/**
 * Quota accounting. GitHub-only — see the module note.
 *
 * `BudgetSnapshot` is deliberately loose here (`unknown`) so this module does not
 * drag GitHub's budget vocabulary into the neutral contract; the GitHub gateway
 * re-declares it with the precise type.
 */
export interface BudgetReporting {
  budget(): unknown;
  history(): Array<{ mine: number; others: number }>;
  refresh(): Promise<unknown>;
  setPaused(paused: boolean): void;
  onBudgetChange(fn: (s: never) => void): () => void;
}

/** The providers this build can route to. */
export type ForgeProviderId = "github" | "forgejo" | "unsupported" | "none";

/** Forge software an instance may run, as reported by detection. */
export type ForgeSoftwareName = "github" | "forgejo" | "gitea" | "gitlab" | "unknown";

/**
 * Reports which providers are actually in play, learned from the repos routed so
 * far. Consumed by the poll cadence: GitHub's degradation ladder must not
 * throttle a setup that contains no GitHub repos (see `cadence.ts`).
 */
export interface ProviderMix {
  providersInUse(): ReadonlySet<ForgeProviderId>;
}

/** Whether a gateway can report which providers it is routing to. */
export function hasProviderMix<G>(gateway: G): gateway is G & ProviderMix {
  return typeof (gateway as Partial<ProviderMix>).providersInUse === "function";
}

/**
 * Whether a gateway can report quota. Use this before wiring budget events or
 * the budget UI, rather than assuming every provider has a quota to report.
 */
export function hasBudgetReporting<G extends ForgeGateway>(gateway: G): gateway is G & BudgetReporting {
  const g = gateway as unknown as Partial<BudgetReporting>;
  return typeof g.budget === "function" && typeof g.onBudgetChange === "function";
}
