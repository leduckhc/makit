# SPEC-51 — Target branch: where a worktree's work lands

**Status:** Shipped (server + app) · **Priority:** P1 · **Branch:** `feat/base-branch`
**Number:** 48 and 49 were taken while this branch was in flight (status/activity, notice layer)
and 50 is claimed by profiles, hence 51.
**Depends on:** SPEC-38 (the PR next-step bar — `PrStatus`, `PrSignal`, the composer strip and the
detail sheet this reuses), SPEC-32 (the GitHub gateway and the `lastKnown` retain-on-throttle path
that makes PR-first resolution possible in the git-only phase), SPEC-11/SPEC-19 (the worktree
action menus this hangs a picker off).
**Design board:** [`mockups/base-branch.html`](../../mockups/base-branch.html) — the rejected
directions and the review findings (B1-B7) are recorded there.

---

## The bug

`repo_service.ts` handed the repo's **default branch** to `diffStat()` and `commitsAhead()` for
every worktree, regardless of what that worktree was actually destined for:

```ts
const stat = await diffStat(e.path, defaultBranch);      // every worktree, always
```

So a worktree stacked on another worktree's branch reported its **parent's work as its own** — a
child with 3 lines of its own on top of a 20-line parent showed `+23`. Meanwhile the base the user
picked at creation time was passed once to `git worktree add` and then discarded, and three
different code paths disagreed about what "the base" even was:

| | Source of truth | Result |
| --- | --- | --- |
| the `+N −M` pill | repo default | wrong for any stacked worktree |
| worktree creation | user's pick, then discarded | lost immediately |
| wrap-up / fast-forward | the PR's `baseRefName ?? default` | right, and inconsistent with the above |

## The reframe

We do not model **base** (a fact about the past, which can be deleted and then poisons everything
downstream). We model **target**: *where this branch's work lands*. It is the same value for four
consumers, so there is one field:

- the diff — `git diff <target>...HEAD`, i.e. **what a pull request into it would contain**
- the ahead count's fallback when a branch has no upstream
- `gh pr create --base` / `gh pr edit --base`
- the branch a wrap-up fast-forwards

Three-dot diff means git finds the merge base live, so **no fork point is stored**. The diff also
self-heals: once a parent lands, `main` contains its commits and `main...HEAD` drops to the child's
own delta with no intervention.

## The contract

**Resolution** — `resolveTargetBranch()` in `repo_service.ts` is the single owner of precedence:

1. primary checkout or detached → **null** (the primary *is* where branches land; a detached
   worktree has no branch to land)
2. an **OPEN** pull request's `baseRefName` — the forge is authoritative while a PR is live, which
   is also how we inherit GitHub's automatic PR retargeting without reimplementing it. A merged or
   closed PR is history and stops overriding; an unrecognised state is treated as not
   authoritative so a state this build predates cannot silently redirect work.
3. the **persisted** user choice
4. the **repo default** — deliberately last, and deliberately the fallback: it reproduces the
   pre-feature behaviour exactly, so upgrading an existing install moves nobody's numbers until
   they choose.

A winner equal to the worktree's own branch is discarded and resolution continues (reachable via
`renameWorktreeBranch`, which keeps the path and therefore the stored target).

**Rule 1 — one vocabulary.** `base` → `target` across server and app. Two documented exceptions:
`baseRefName` (GitHub's own field, mirrored from their API) and two **one-release** wire aliases —
`worktree.create` and `worktree.wrapUp` read `env.targetBranch ?? env.baseBranch`, the app sends
both keys, and `WrapUpReport.fromJson` reads both sets. The wrapUp alias is load-bearing, not
cosmetic: a client that predates the rename would otherwise send a key the server ignores, the
manager's `?? detectDefaultBranch()` fallback would fast-forward the **wrong branch**, and the ack
would report success. Guarded by a test that fails the day someone deletes the alias without
shipping the app first.

**Rule 2 — a branch rename follows through.** `renameWorktreeBranch` calls `renameTargetBranch`,
so every worktree landing in that branch moves with it. Without it a rename leaves them aiming at
a name that no longer resolves, for a rename that was none of their business.

**Rule 3 — wrap-up hands its target down, recursively.** Wrapping up a branch repoints everything
that was landing in it to where *it* landed, via `resolveThroughChain` — so `leaf → mid → grand →
main` collapses correctly when the stack lands bottom-up. Guarded against cycles and
self-reference; refuses a default branch that is not itself live.

**Rule 4 — a target that vanishes without a wrap-up falls back, and says so.** Someone ran
`git branch -D`, or the forge auto-deleted a merged head: there was no wrap-up, so nothing was
handed down, and from there "merged" and "abandoned" are indistinguishable.
`repairVanishedTargets` walks the chain first (so a stack that landed outside makit still
collapses to where it really went) then falls back to the repo default, and records
`retargetedFrom`. Cleared the moment the user picks a target explicitly — by then they own the
value and there is nothing left to tell them.

**B7 — the lifecycle converges.** `adoptLivePrTargets` persists a live PR's base whenever it
disagrees with what is stored, so the two backing stores stop arguing at every edge: a PR opened
by hand against a different base is caught up, closing or reopening falls back to where the PR
actually pointed rather than a pre-PR value, and GitHub's auto-retarget-then-auto-close sequence
no longer drops us onto a stale target. Announced only when it *overrode* a value we already had —
agreement is not news.

## Failure reporting

`DiffStat.targetResolved` is false when the target cannot be resolved. This matters because the
failure mode is **not a zero**: when the `target...HEAD` leg fails, only that leg is skipped —
working-tree and untracked files still count — so an unresolvable target yields a *plausible small*
number that reads as "barely diverged". Clients suppress the pill (`Worktree.showsDiff`) rather
than publish a partial count, and the state is said out loud rather than merely hidden.

## Where it lives in the UI

The target is **create-time config**, so it spends no first-glance space: the worktree row and the
composer strip are unchanged. Three disclosures, one shared picker:

| Home | Surface | Why |
| --- | --- | --- |
| **canonical** | worktree actions — `worktree_actions.dart` (mobile sheet) and `desktop_sidebar.dart` (hover `⋯`) | the target is a property of a **worktree**, and this is the only per-worktree menu — and the only entry that exists when a worktree has no session |
| convenience | the composer's `Ship it ⌄` menu, a "This worktree" group at the bottom | where your hand already is at ship time; prints its value inline |
| display | the detail sheet header — `branch ≫ target` | the only place head and target appear together, and with a PR the only place the branch appears at all (`status.identity` is `#<number>`) |

`≫` is `PhosphorIconsLight.caretDoubleRight` — *append into*, distinguishing a merge destination
from ordinary navigation. The line is asymmetric on purpose: the source is muted, the target
carries the emphasis and the affordance, because a pair at equal weight reads as two unrelated
facts when the point is that the right half is a control.

The picker ranks candidates by *why* each is one — forked-from, repo default, other worktrees, all
branches — and previews the diff each would produce, capped at 4 through a bounded pool so opening
it cannot storm git. A local-only branch is listed **disabled with the reason**, because a PR base
must exist on the remote — *unless the repo has no remote at all*, in which case the rule is
vacuous and enforcing it would disable every row.

## No stale state

One `broadcastReposSnapshot()` refreshes every consumer, because there is no diff-level cache and
`reposProvider` is the app's single source of truth. `worktree.setTarget` validates the ref,
persists **atomically**, then broadcasts, then acks — in that order, because persisting after the
broadcast would compute the snapshot against the old target and ship stale numbers that look
correct until some unrelated event moved them.

Two surfaces had to stop freezing their facts: `PrDetailBody` took a `PrStatus` as a constructor
parameter (stale-by-construction once its header hosted the picker) and `showWorktreeActions`
closed over its `Worktree`. Both now re-derive from `reposProvider`. `showPrDirectConfirm` still
freezes its values deliberately — a confirmation must describe what the user agreed to.

Non-obvious consumers that follow from a target change: `hasChanges` gates the row's meta-line
visibility, and `insertions + deletions` drives worktree **sort order**, so retargeting can move a
row between the active and inactive partitions.

## Decisions worth remembering

- **Ahead/behind are upstream metrics, not target metrics.** `commitsAhead` prefers
  `@{upstream}..HEAD` and only falls back to the target ref when a branch has no upstream;
  `commitsBehind` takes no ref at all. Retargeting moves the diff and not these counts, which is
  correct — they answer "what would a push send / a pull fetch". A target-relative commit count was
  considered and dropped as YAGNI: the diff already conveys PR size.
- **`closestAncestorBranch`, not `merge-base --fork-point`.** Fork-point consults the reflog, which
  is empty for a freshly created worktree and gone after a clone — it answers "unknown" exactly
  when a suggestion is most wanted. Ties break by the caller's candidate order.
- **The announcement is added last in the signal list.** `PrStatus.loud` is `signals.first`, so
  position *is* priority. Inserted earlier it became the composer strip's headline and pushed
  `1 commit unpushed` into `+1 more`, letting an informational note crowd out something actionable.

## Not done

- Deleting the two one-release wire aliases (`env.baseBranch`, the `base*` report keys) once an app
  carrying the new keys has shipped.
- A target-relative commit count, if "how many commits would this PR add" ever earns its place.
