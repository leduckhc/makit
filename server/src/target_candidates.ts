/**
 * Ranked target-branch candidates for the picker.
 *
 * A flat alphabetical branch list is useless in a repo with forty branches: the
 * answer is almost always one of four things, so candidates are grouped by *why*
 * they are a candidate and each of the top few carries a preview of the diff it
 * would produce.
 *
 * Lives apart from `repo_service` because it is per-request (a picker opening),
 * not per-snapshot: it must never be dragged into the broadcast fan-out, where N
 * candidates x M worktrees would storm git.
 */

import { mapLimit } from "./concurrency.js";
import {
  closestAncestorBranch,
  hasOriginRemote,
  detectDefaultBranch,
  diffStat,
  listLocalBranches,
  listRemoteBranchNames,
  listWorktrees,
} from "./git.js";

/** Why a branch is being offered. Drives the picker's section headers. */
export type TargetCandidateGroup = "forkedFrom" | "default" | "worktree" | "other";

export interface TargetCandidate {
  branch: string;
  group: TargetCandidateGroup;
  /**
   * Whether the branch exists on a remote. A pull-request base must, so a
   * local-only branch is listed **disabled with the reason** rather than accepted
   * and then rejected by `gh` later.
   */
  onRemote: boolean;
  /** True for the worktree's own branch: offered, disabled, "this worktree". */
  isSelf: boolean;
  /** What the diff would become. Absent when not previewed (see PREVIEW_LIMIT). */
  insertions?: number;
  deletions?: number;
}

/**
 * How many of the ranked candidates get a diff preview.
 *
 * Each preview is one `git diff --numstat <cand>...HEAD` — the same call the
 * snapshot already makes, but N of them at once the instant a picker opens. Only
 * the ranked few are worth it; "All branches" renders names and fills previews
 * on demand.
 */
export const PREVIEW_LIMIT = 4;

/** Concurrency for the preview diffs, so opening the picker cannot storm git. */
const PREVIEW_CONCURRENCY = 4;

/**
 * Where a worktree should land when the branch it was aiming at is gone.
 *
 * Follows the chain: if `start` is gone but we recorded where *it* was going,
 * try that, and keep going — a stack three deep collapses to wherever the stack
 * actually landed rather than to the repo default, which would silently move the
 * work to a different destination.
 *
 * Guards against a cycle (A lands in B while B lands in A, then both vanish) and
 * against a self-reference, either of which would otherwise loop or resolve to a
 * branch that does not exist.
 *
 * Returns the repo default when the chain dead-ends, and null when even that is
 * missing — the only genuinely unanswerable case.
 */
export function resolveThroughChain(
  start: string,
  ctx: {
    /** Branch names that currently exist. */
    live: ReadonlySet<string>;
    /** Branch -> the branch it lands in, for branches we still have a record of. */
    branchTarget: Readonly<Record<string, string>>;
    defaultBranch: string | null;
  },
): string | null {
  const { live, branchTarget, defaultBranch } = ctx;
  const seen = new Set<string>();
  let cur: string | undefined = start;
  while (cur && !seen.has(cur)) {
    if (live.has(cur)) return cur;
    seen.add(cur);
    cur = branchTarget[cur];
  }
  // The default is only an answer if it actually exists. `detectDefaultBranch`
  // normally guarantees that, but a repo mid-rename (or with origin/HEAD pointing
  // at a deleted branch) can hand back a name that resolves to nothing, and
  // returning it would just move the "target is gone" problem one branch over.
  if (defaultBranch && live.has(defaultBranch)) return defaultBranch;
  return null;
}

/**
 * Build the ranked candidate list for `worktreePath`.
 *
 * Order, and why:
 *  1. **forkedFrom** — the closest ancestor branch. The honest default, and the
 *     one today's pill gets wrong.
 *  2. **default** — the repo default; what you want the moment a stack lands.
 *  3. **worktree** — branches checked out in other worktrees: the stacked case,
 *     and the only candidates whose target is a moving thing you can watch.
 *  4. **other** — everything else, alphabetical, behind a filter in the UI.
 *
 * Each branch appears exactly once, in its highest-priority group. The worktree's
 * own branch is included (flagged `isSelf`) rather than hidden, so the picker can
 * explain why it is not selectable instead of leaving a confusing gap.
 */
export async function targetCandidates(
  repoPath: string,
  worktreePath: string,
): Promise<TargetCandidate[]> {
  const [locals, onRemote, defaultBranch, trees, originExists] = await Promise.all([
    listLocalBranches(repoPath),
    listRemoteBranchNames(repoPath),
    detectDefaultBranch(repoPath),
    listWorktrees(repoPath),
    hasOriginRemote(repoPath),
  ]);
  if (locals.length === 0) return [];

  const self = trees.find((t) => t.path === worktreePath)?.branch ?? null;
  // Candidate order matters: `closestAncestorBranch` breaks distance ties by it,
  // and the repo default is the tie we most want to win.
  const ordered = [
    ...(defaultBranch && locals.includes(defaultBranch) ? [defaultBranch] : []),
    ...locals.filter((b) => b !== defaultBranch),
  ];
  const forkedFrom = await closestAncestorBranch(worktreePath, ordered);

  const otherWorktreeBranches = new Set(
    trees
      .filter((t) => t.path !== worktreePath && t.branch)
      .map((t) => t.branch as string),
  );

  const groupOf = (branch: string): TargetCandidateGroup => {
    if (branch === forkedFrom) return "forkedFrom";
    if (branch === defaultBranch) return "default";
    if (otherWorktreeBranches.has(branch)) return "worktree";
    return "other";
  };

  const rank: Record<TargetCandidateGroup, number> = {
    forkedFrom: 0,
    default: 1,
    worktree: 2,
    other: 3,
  };

  const candidates: TargetCandidate[] = locals.map((branch) => ({
    branch,
    group: groupOf(branch),
    // The push-state gate exists because a PULL REQUEST base must live on the
    // remote. With no `origin` there is no pull request for it to constrain, while
    // the target still drives the diff and the merge destination — so the rule is
    // vacuous and enforcing it would disable every row and leave the picker
    // unusable. (Found by driving the real app against a plain `git init` repo:
    // every candidate read "not pushed yet".)
    //
    // Gated on `origin` specifically, matching `listRemoteBranchNames`' scope: a
    // repo whose only remote is `upstream` has a remote but no origin branches, so
    // an "any remote" gate would switch the rule ON against an EMPTY set and
    // disable every candidate.
    onRemote: originExists ? onRemote.has(branch) : true,
    isSelf: branch === self,
  }));

  candidates.sort((a, b) => {
    const byGroup = rank[a.group] - rank[b.group];
    if (byGroup !== 0) return byGroup;
    // Self last within its group: it is present only to be explained.
    if (a.isSelf !== b.isSelf) return a.isSelf ? 1 : -1;
    return a.branch.localeCompare(b.branch);
  });

  // Preview only the leading SELECTABLE candidates: not self, and on the remote
  // (an off-remote candidate is offered but disabled, so it must not consume a
  // preview slot a selectable remote-backed candidate could have used). In a
  // repo with no remote every candidate is `onRemote: true` (the vacuous rule
  // above), so this does not starve previews there.
  const previewable = candidates
    .filter((c) => !c.isSelf && c.onRemote)
    .slice(0, PREVIEW_LIMIT);
  const stats = await mapLimit(previewable, PREVIEW_CONCURRENCY, (c) =>
    diffStat(worktreePath, c.branch),
  );
  previewable.forEach((c, i) => {
    const s = stats[i];
    // A preview that could not be measured is omitted rather than shown as zero —
    // the same reason `DiffStat.targetResolved` exists.
    if (s && s.targetResolved) {
      c.insertions = s.insertions;
      c.deletions = s.deletions;
    }
  });

  return candidates;
}
