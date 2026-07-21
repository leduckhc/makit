/**
 * PR status poller (SPEC-23) — the server-side answer to "PR status never
 * updates on its own". GitHub has no client push/stream API (see
 * docs/research/2026-07-13-github-gitlab-live-updates.md §2), so the only
 * near-term way to surface remote changes (CI finishing, a review landing, a
 * merge) is to poll. This poller is the "Tier 2" design from that research:
 *
 *   - **Eligible branches, coalesced.** One poller shared across every client;
 *     clients never talk to GitHub. The tracked set mirrors `enrichPrs`
 *     eligibility (every secondary, branched worktree) so the poller can
 *     *discover* a PR that appears on a branch from any source — created in
 *     makit, by another agent, or in the GitHub UI — not merely refresh a PR
 *     it already knew about. The set is refreshed from each `repos.snapshot`
 *     via {@link PrWatcher.sync}.
 *   - **Change-gated broadcast.** Each tick re-fetches every tracked PR and
 *     compares a structural signature to the last-known one; `onChange` (which
 *     re-runs `broadcastReposSnapshot`) fires only when something actually
 *     changed, so idle PRs cost one cheap `gh` call and zero client traffic.
 *   - **Adaptive interval.** Poll fast (~10s) while any tracked PR has
 *     in-flight checks; back off to slow (~60s) once every PR's checks are
 *     terminal. A small jitter avoids thundering-herd alignment. The timer is
 *     `unref`'d so it never keeps the process alive.
 *
 * Webhooks (true push) remain deferred — a laptop server has no public HTTPS
 * endpoint to receive them (research §5, Tier 1).
 */

import type { PullRequestInfo } from "./git.js";
import type { PullRequestDTO, RepoDTO } from "./protocol.js";

/** A PR to poll, identified by the repo it lives in and its head branch. */
interface TrackedPr {
  repoPath: string;
  branch: string;
}

export interface PrWatcherOptions {
  /** Fetch current PR status for a head branch (typically `findOpenPr`). */
  fetchPr: (repoPath: string, branch: string) => Promise<PullRequestInfo | null>;
  /** Called when a tracked PR's status changed — re-broadcasts the snapshot. */
  onChange: () => void;
  /** Poll interval while any tracked PR has in-flight checks. Default 10s. */
  fastMs?: number;
  /** Poll interval once every tracked PR's checks are terminal. Default 60s. */
  slowMs?: number;
  /** Max random jitter added to each interval. Default 3s. */
  jitterMs?: number;
  /** Injectable timer (tests). Defaults to global setTimeout. */
  setTimer?: (fn: () => void, ms: number) => { unref?: () => void };
  /** Injectable clearer (tests). Defaults to global clearTimeout. */
  clearTimer?: (handle: unknown) => void;
}

export interface PrWatcher {
  /** Refresh the tracked PR set from a freshly-enriched repos snapshot. */
  sync(repos: RepoDTO[]): void;
  /** Run one poll cycle now; resolves to whether a change was broadcast. */
  pollOnce(): Promise<boolean>;
  /** Stop polling and drop all state. */
  close(): void;
}

/** Stable key for a tracked PR (a repo path + its head branch). */
function keyOf(repoPath: string, branch: string): string {
  return `${repoPath}\0${branch}`;
}

/** Sentinel signature for a tracked branch that has no open PR (yet). */
const NO_PR = "\0none";

/**
 * Structural signature of the PR fields that matter to the UI. Two PRs with
 * the same signature render identically, so no broadcast is warranted. Kept
 * deliberately narrow (identity + mergeability + per-check verdict) so cosmetic
 * churn (timestamps, ordering) doesn't trigger needless fan-out.
 */
function signature(pr: {
  state: string;
  isDraft: boolean;
  mergeable: string | null;
  mergeStateStatus: string | null;
  checkRollup: string;
  checks: Array<{ name: string; bucket: string }>;
}): string {
  const checks = [...pr.checks]
    .map((c) => `${c.name}:${c.bucket}`)
    .sort()
    .join(",");
  return [pr.state, pr.isDraft, pr.mergeable, pr.mergeStateStatus, pr.checkRollup, checks].join("|");
}

/** Signature of a worktree's PR, or the {@link NO_PR} sentinel when absent. */
function sigOf(pr: PullRequestDTO | null): string {
  return pr ? signature(pr) : NO_PR;
}

export function watchPrs(opts: PrWatcherOptions): PrWatcher {
  const fastMs = opts.fastMs ?? 10_000;
  const slowMs = opts.slowMs ?? 60_000;
  const jitterMs = opts.jitterMs ?? 3_000;
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = opts.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));

  // Tracked PRs and the last-known signature per key. Seeded from the snapshot
  // that introduced each PR, so a freshly-appeared PR doesn't immediately
  // re-broadcast (its poll signature matches the seed).
  const tracked = new Map<string, TrackedPr>();
  const lastSig = new Map<string, string>();
  // Whether the most recent poll saw any in-flight checks (drives the cadence).
  let anyPending = false;
  let timer: unknown;
  let closed = false;

  const schedule = (): void => {
    if (closed) return;
    if (timer) clearTimer(timer);
    if (tracked.size === 0) {
      timer = undefined;
      return;
    }
    const base = anyPending ? fastMs : slowMs;
    const delay = base + Math.floor(Math.random() * jitterMs);
    const handle = setTimer(() => {
      void pollOnce().finally(schedule);
    }, delay);
    handle.unref?.();
    timer = handle;
  };

  async function pollOnce(): Promise<boolean> {
    if (closed || tracked.size === 0) {
      anyPending = false;
      return false;
    }
    const entries = [...tracked.values()];
    const results = await Promise.all(
      entries.map((t) =>
        opts
          .fetchPr(t.repoPath, t.branch)
          .then((pr) => ({ t, pr }))
          .catch(() => ({ t, pr: null as PullRequestInfo | null })),
      ),
    );

    let changed = false;
    let pending = false;
    for (const { t, pr } of results) {
      const key = keyOf(t.repoPath, t.branch);
      // A tracked PR that vanished (closed/merged out of the open set) or that
      // errored transiently: leave its last signature so a broadcast (which
      // re-derives the tracked set) is the authority on dropping it.
      if (!pr) continue;
      if (pr.checkRollup === "pending") pending = true;
      const sig = signature(pr);
      if (lastSig.get(key) !== sig) {
        lastSig.set(key, sig);
        changed = true;
      }
    }
    anyPending = pending;
    if (changed) opts.onChange();
    return changed;
  }

  return {
    sync(repos: RepoDTO[]): void {
      if (closed) return;
      const next = new Map<string, TrackedPr>();
      for (const repo of repos) {
        for (const w of repo.worktrees) {
          // Mirror enrichPrs eligibility: any secondary, branched worktree can
          // grow a PR at any time. Tracking them all — not just ones that
          // already have a known PR — is what lets the poller *discover* a
          // newly-created PR (from makit, another agent, or the GitHub UI),
          // rather than only refreshing an existing one.
          if (!w.branch || w.isPrimary) continue;
          const key = keyOf(repo.path, w.branch);
          next.set(key, { repoPath: repo.path, branch: w.branch });
          // Seed / refresh the baseline from the authoritative snapshot (a real
          // PR's signature, or the "no PR yet" sentinel) so the next poll only
          // fires on a genuine change since this broadcast.
          lastSig.set(key, sigOf(w.pr));
        }
      }
      // Drop signatures for PRs no longer tracked.
      for (const key of [...lastSig.keys()]) if (!next.has(key)) lastSig.delete(key);
      tracked.clear();
      for (const [k, v] of next) tracked.set(k, v);
      schedule();
    },
    pollOnce,
    close(): void {
      closed = true;
      if (timer) clearTimer(timer);
      timer = undefined;
      tracked.clear();
      lastSig.clear();
    },
  };
}
