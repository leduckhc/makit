# SPEC-38 — PR actions: the next-step bar

**Status:** Implemented; every gap in §11 closed, with 3 accepted limitations in §11a · **Priority:** P2 · **Branch:** `feat-pr-actions`
**Depends on:** SPEC-23 (composer PR bar + canned prompts — this replaces its UI),
SPEC-32 (GitHub gateway: `PrLookup`, quota ladder, cache), SPEC-11 (repo-centric mobile home),
SPEC-19 (worktree lifecycle)

**Review record:** [`2026-08-06-SPEC-38-REVIEW.md`](./2026-08-06-SPEC-38-REVIEW.md) — five passes,
including what was rejected and why.

**Mockups:** [`mockups/pr-actions.html`](../../mockups/pr-actions.html) (A/B/C survey — direction B
chosen), [`mockups/pr-actions-next-step.html`](../../mockups/pr-actions-next-step.html) (as-built
reference, incl. §10 action catalogue)

**Scope:**
*app (new):* `app/lib/ui/widgets/pr_signals.dart` (derivation),
`app/lib/ui/widgets/pr_tone.dart` (tone → colour, `PrDot` → colour (§8.1), `PrFactLabel`),
`app/lib/ui/widgets/pr_detail.dart` (detail body + CTA menu + `PrCheckRow`),
`app/lib/ui/widgets/wrap_up.dart` (remedy dispatch + confirms).
*app (changed):* `app/lib/desktop/chat/pr_bar.dart` (rewritten),
`app/lib/ui/composer/composer.dart` (`header` slot — the bar's placement, D11),
`app/lib/ui/home/repo_chips.dart` (`PrPill` → `PrStatusChip`),
`app/lib/ui/home/worktree_row.dart`, `app/lib/ui/session/session_pr_chip.dart` (rewritten),
`app/lib/ui/session/session_screen.dart`, `app/lib/desktop/chat/desktop_chat_pane.dart`,
`app/lib/desktop/chat/worktree_starter.dart`, `app/lib/store/models.dart`,
`app/lib/store/store.dart`, `app/lib/ui/widgets/pr_actions.dart`,
`app/lib/ui/widgets/pr_state_style.dart`, `app/lib/store/prefs/preference_entries.dart`,
`app/lib/desktop/settings/sections/agents_chat_section.dart`.
*app (deleted):* `app/lib/ui/widgets/pr_sheet.dart`.
*server:* `server/src/git.ts` (`syncBaseBranch`, `deleteBranch`),
`server/src/manager.ts` (`wrapUpWorktree`, `squashMergePr`, `markPrReady`, `updatePrBranch`),
`server/src/github/queries.ts` (`baseRefName`, `prMutationArgv`),
`server/src/github/gateway.ts` (`mutatePr` + cache invalidation),
`server/src/protocol.ts` (5 `CmdKind`s — `worktree.wrapUp`, `worktree.discard`, `pr.markReady`,
`pr.updateBranch`, `pr.squashMerge` — plus `PullRequestDTO.baseRefName`),
`server/src/ws/commands/worktree.ts`.

---

## 1 · Goal

Make the PR surface **say what is wrong and offer the one thing that fixes it** — on the desktop
composer, the mobile home row, and the mobile session screen — and give a pull request the two
endings it never had: **land it** and **tidy up after it**.

## 2 · The problem with SPEC-23's bar

Evidenced against the shipped code, not asserted:

1. **Two zones that secretly depend on each other.** `_situationFor()` in `pr_bar.dart` computed
   the single most urgent fact *and* the split button's default action. Nothing on screen drew that
   line, so the button looked arbitrarily preset.
2. **It under-reported.** An `if/if/if → return` ladder returned exactly one chip. An unpushed
   commit outranked a red build *and* three unresolved threads, so both vanished; the pill's dot was
   the only remaining hint that CI was broken.
3. **The menu was a static enum dump.** All six prompts on every PR regardless of state: "Pull" with
   nothing to pull, "Fix PR" on a green build, "Resolve comments" with zero comments.
4. **Everything routed through the agent.** Even deterministic `git`/`gh` operations became a prompt
   the user had to review and send.
5. **Merged and closed were dead ends.** A landed PR was offered "Fix PR". The real next step —
   remove the worktree, bring the base branch up to date — existed nowhere in the PR surface; worktree
   deletion lived behind a mobile long-press and in the desktop sidebar.
6. **The three pills had already drifted once.** `prPillColors`' own docstring records that the home
   row tinted open PRs by state while the other two tinted by CI verdict, so an open failing PR read
   red on two surfaces and brand-green on the third.

## 3 · Direction

Three directions were mocked (`mockups/pr-actions.html`). **B — "one next step"** was chosen, in its
**B1** flavour: the bar states the loudest fact and counts the rest behind a `+n more` disclosure.

```
● #142 · 2 checks failing   +2 more                    [ ✨ Fix ▾ ]
```

The objection to B1 ("a disclosure hides facts") is answered by what the disclosure *opens*: the full
fact list, each row with its own remedy. The bar is quiet; nothing becomes unreachable. Secondary
facts cost one extra tap — that is B1's accepted price, recorded in the mockup's scorecard.

A and C were not built. What survived regardless of direction: the lifecycle-driven CTA, the two
action registers, the regrouped menu, the precedence table, and both endings.

## 4 · One derivation, three surfaces

`prStatus()` (`pr_signals.dart`) is the single source of truth. It takes primitives (PR, branch, three
sync counts, `isPrimary`) and returns:

```dart
class PrStatus {
  String identity;        // '#142', else the branch name, else 'detached'
  PrTone tone;            // the loud signal's tone — the sentence's hue
  PrDot dot;              // what the status dot reports — the PR's own state (§8.1)
  List<PrSignal> signals; // facts, loudest first, never empty
  PrCta cta;
  double? checkProgress;  // fraction of checks reported, or null
  bool stale;
  PrSignal get loud => signals.first;
  int get more => signals.length - 1;
  bool get hasPr; bool get isQuiet;
}
class PrSignal { String label; PrTone tone; PrRemedy? remedy; String? detail; }
sealed class PrRemedy { }            // PromptRemedy | DirectRemedy | MagicRemedy
class PrCta { String label; PrTone tone; PrRemedy? remedy; }  // remedy == null ⇒ idle
```

Every surface renders from this, which is what structurally prevents the §2.6 drift from recurring.
The widgets decide only *how much* fits: the bar shows `loud` + `+n more`; the detail shows all.

**Surfaces without a composer.** The mobile home list has nowhere to put a prompt, so it passes
`canInsertPrompt: false` and the detail hides every prompt-backed remedy — the facts are still
reported, only the dead buttons go. The direct ops stay, because tidying up needs no composer. Showing
them would mean a tap that saves a preference, composes text, closes the sheet and drops it.

**`isQuiet`** — `!hasPr && !signals.any((s) => s.remedy != null)` — means "no PR to reach and nothing
outstanding". Quiet worktrees render **no chip at all** on the mobile row and session screen. The CTA
is deliberately ignored here: a clean branch still *offers* "Create PR", but an offer is not a fact
worth a chip (see §11 decision D6).

## 5 · Precedence (normative)

The CTA is the first matching row, top down, and preserves SPEC-23's relative order for the rows it
inherited so the rewrite cannot silently reshuffle the offered action.

| # | Condition | Signal label | Remedy |
| --- | --- | --- | --- |
| — | `state: MERGED`\|`CLOSED` (short-circuits all below) | `merged` / `closed without merging` | Wrap up / Discard worktree |
| 1 | `uncommittedFiles > 0` | `N files uncommitted` | Commit and push |
| 2 | `commitsBehind > 0` | `N commits behind` | Pull |
| 3 | `commitsAhead > 0` | `N commits unpushed` | Push |
| 4 | `mergeable: CONFLICTING` | `conflicts with the base` | Pull |
| 5 | `checkRollup: fail` | `N checks failing`, or `CI failing` when the list was shed | Fix PR |
| 6 | `mergeStateStatus: BEHIND` | `the base branch moved on` | Update branch |
| 7 | unresolved threads > 0 (and not `unresolvedUnknown`) | `N threads open` | Resolve comments |
| 8 | checks pending > 0 | `N of M checks still running` | — (none) |
| 9 | `isDraft` | `still a draft` | Mark ready |
| 10 | all-clear **and** `mergeable: MERGEABLE` and not `BLOCKED` | `ready to merge` | Squash & merge |
| 11 | all-clear otherwise | `N checks passed` / `green and up to date` / `ready for a PR` / `clean` | — |

Rows inherited unchanged from SPEC-23's `_situationFor()` are **1, 2, 3, 5 and 7** (uncommitted,
behind, unpushed, red build, threads); rows 4, 6, 9, 10 and the endings are new. The *Remedy* column
names the underlying action, not the button string — every surface shortens some (`Fix PR` → `Fix`,
`Resolve comments` → `Resolve`) because the sentence beside the button has already said what is wrong.
One source for those verbs (`prRemedyLabel`), so the bar, the fact rows and the menu cannot drift; see
D12 for why `Fix` is deliberately also the magic remedy's verb.

**Rationale for the new rows.** Row 4 before 5: conflicts make a build result moot. Row 6 after 5:
updating the branch reruns CI anyway. Row 9 **last**: marking a half-finished PR ready is not a next
step. Row 10 only in the all-clear, because reaching there already implies no conflicts, no red or
in-flight build, no threads, no local work and not a draft.

**Row 11 is `isPrimary`-aware:** the primary checkout reports `clean` and is offered nothing — you do
not raise a pull request for `main`, and it cannot be wrapped up because removing it would take the
repo with it.

### Two overrides on top of precedence

- **Magic Fix.** When **two or more** signals carry a `PromptRemedy` **and every actionable signal is
  prompt-backed**, the CTA becomes `Fix` (`MagicRemedy`) — with several problems, "fix everything"
  genuinely *is* the single next step. The sentence still names the loudest fact; the individual
  remedies stay in the detail list and the menu. With one problem it is not offered: it would be that
  problem's own remedy under a vaguer label. The second clause matters: the composed prompt carries
  prompt-backed facts only, so offering `Fix` while a *direct* op is outstanding (say
  `the base branch moved on`) would promise to fix everything and silently skip that one.
- **Tone promotion.** A CTA whose loud fact is `quiet` is drawn as `attention`, because a solid grey
  button reads as *disabled*. Quiet facts do carry remedies: `still a draft`, `ready to merge`, and —
  because a draft mutes its own facts — a draft's failing build or open threads. Promotion is for the
  button's tint only; the fact itself stays quiet wherever it is listed.

## 6 · Action catalogue (normative)

Two registers, visually distinct so "ask the agent to try" and "delete this worktree now" can never be
confused: **agent prompts** are tonal and insert text into the composer (never sending); **direct ops**
are filled and run a server command.

### 6.1 Direct ops — `cwd` = the repo, not the worktree

| Action | Command | Confirm |
| --- | --- | --- |
| Squash & merge | `gh pr merge <n> --squash` | yes |
| Mark ready | `gh pr ready <n>` | no |
| Update branch | `gh pr update-branch <n>` | no |
| Discard worktree | `git worktree remove <path> --force` | yes |
| Wrap up | 4 steps, below | yes |

```sh
# Wrap up — server/src/manager.ts#wrapUpWorktree
# 1. remove the worktree FIRST. Reconciling sessions before git succeeded could
#    orphan them unrecoverably, leaving the worktree on disk without its sessions.
git worktree remove <path> --force
# 2. THEN reconcile sessions bound to it (SPEC-29): live → archived (transcript and
#    resume handle preserved), drafts → killed, already-archived → left alone.
# 3. delete the branch it held (-D, not -d: a squash-merge leaves commits git
#    cannot find on the base, so -d would refuse a branch that demonstrably landed)
git branch -D <branch>
# 4. catch the base branch up — fast-forward ONLY, never forced
git fetch origin <base>
git rev-list --count <base>..origin/<base>        # 0 → stop, already current
git -C <hostWorktree> merge --ff-only origin/<base>   # if <base> is checked out
git fetch origin <base>:<base>                        # otherwise (ref only)
```

Normative properties:

- **`gh pr merge` must carry a strategy flag.** Without one it drops into an interactive prompt, which
  would hang a non-tty server process forever.
- **No `--delete-branch` on merge.** Merging and tidying are separate decisions; deleting the branch
  there would pull the worktree out from under any session still running in it. The PR then reports
  `MERGED` and the surface offers Wrap up, which stops those sessions first.
- **Mutations address the PR by number.** `gh pr ready`/`update-branch`/`merge` with no argument infer
  the PR from the *checked-out* branch, but the server's `cwd` is the repo — inference would resolve
  the repo's current branch. `prMutationArgv` always passes `<n>`.
- **Wrap up step 4 is best-effort and reported, never fatal.** By then the worktree is gone, so
  throwing would report a mostly-done job as a total failure. A divergent base (local commits never
  pushed) is **refused, not forced**. The ack carries `branchDeleted`, `baseBranch`, `baseUpdated`,
  `baseReason`; the app renders `Removed feat/x · main updated` or `… · main unchanged` with a **Why?**
  action.
- **`<base>` is the PR's own `baseRefName`**, newly fetched (§7), falling back to the repo's default
  branch. The base is not always `main`.
- **Only step 1 is fatal.** If the worktree survives, nothing was tidied and the caller says so. Steps
  3 and 4 are best-effort and *reported* (`branchReason`, `baseReason`) for the same reason: by then the
  worktree is gone and the client cannot retry, because the path is no longer a registered worktree.
- **The confirmed branch is checked before anything is removed.** The dialog names a branch from the
  app's snapshot, but the server resolves it again when it runs; a worktree that has since been switched
  to another branch would otherwise have *that* branch deleted, unwarned. The command carries
  `expectBranch` and refuses on mismatch.

### 6.2 Agent prompts

Verbatim defaults live in `pr_actions.dart` and are reproduced in the mockup's §10. Each is
overridable in Settings › Agents & Chat; blank means "use the built-in".

The **magic Fix** is composed at run time: an overridable preamble
(`prMagicFixPromptPreference`, default `kMagicFixPreamble`) followed by the actual problems as a
checklist, with each signal's `detail` (e.g. which checks failed) when known. The list is **data, not
wording**, and is not overridable. It is emitted in **precedence order** (§5) — `signals` is already
ordered, and it must stay that way: handing over `{uncommitted, behind}` unordered invites a pull onto
a dirty tree. It is enumerated rather than left implicit because the agent cannot
see the bar: "fix the PR" would make it rediscover the failing checks, the open threads and the
unpushed commit for itself, and possibly miss one.

### 6.3 Confirms

`needsConfirm(op)` gates the dialog. It is **not** "destructive": squash-merging destroys nothing
locally, but it publishes to a shared branch and cannot be undone in one click, so it asks. The two
reversible GitHub changes do not — `gh pr ready --undo` reverses Mark ready, Update branch only adds a
commit, and neither touches the working tree. A dialog on those would train the user to dismiss
dialogs unread, which is exactly what would make the wrap-up and merge dialogs worthless.

Each dialog states what it will actually do, in order, and names the branches involved. The merge
dialog additionally states what it will **not** do ("leave this worktree and its sessions alone"),
because GitHub's own button offers to delete the branch there and then.

### 6.4 Provenance of each action

Recorded because AGENTS.md §3 requires every change to trace to a request, and two of these were
proposed by the implementer rather than asked for.

| Action | Asked for |
| --- | --- |
| Wrap up (remove worktree + sync base branch) | Directly: *"a new action that will delete the worktree and update the target branch"* |
| Squash & merge | Directly: *"include a button that will run Squash & Merge similarly as github does it"* |
| Magic Fix | Directly: *"one 'magic' button '[magic icon] Fix', that will resolve all the open PR issues"* |
| Discard worktree | Implied — the closed-PR counterpart of Wrap up, needed so `CLOSED` is not left a dead end |
| **Mark ready**, **Update branch** | **Proposed in the mockup and explicitly flagged as speculative**; approved on review with *"do it, of course"* |

## 7 · Server protocol

New `CmdKind`s, each acking and rebroadcasting the repos snapshot:

| Kind | Params | Ack |
| --- | --- | --- |
| `worktree.wrapUp` | `projectId`, `worktreePath`, `baseBranch?`, `expectBranch?` | `projectId`, `worktreePath`, `branchDeleted?`, `branchReason?`, `baseBranch?`, `baseUpdated`, `baseReason?` |
| `worktree.discard` | `projectId`, `worktreePath`, `expectBranch?` | as above, minus the base fields |
| `pr.markReady` | `projectId`, `worktreePath` | `projectId`, `worktreePath` |
| `pr.updateBranch` | ″ | ″ |
| `pr.squashMerge` | ″ | ″ |

`PullRequestDTO.baseRefName?: string | null` is added and requested from `gh`
(`prForBranchArgv`'s `--json` set). **Optional**, matching `stale?`/`unresolvedUnknown?`, so an app
talking to an older server still decodes and the server falls back to the repo default branch.

`GithubGateway.mutatePr(repoPath, branch, number, verb)` runs the mutation costed on `core` and, on
success, **invalidates every cached view of that PR** — the `pr:<repoPath>:<branch>` lookup *and* every
`openPrs:<repoPath>:*` list, which backs the "New worktree from PR" picker (a squash-merged PR left in
it leads to a checkout that fails). Without that the UI would keep reporting the state the mutation just
changed until the TTL expired.

Invalidation also **bumps a per-key generation counter**, and both cache writers compare the generation
they started with before storing. A lookup already in flight when the mutation landed describes the
*pre*-mutation state, and would otherwise re-seed exactly what was just invalidated.

## 8 · Visual language

- **The dot is the only ambient graphic**, so it carries two things: hue for the verdict, and a
  determinate **arc** for check progress. Determinate on purpose — a rollup is a *count* (4 of 12
  reported), so a spinner would overstate what is unknown. Hollow when there is nothing to report
  (§8.1).
- **Tone hues are the check hues.** `prToneColor` reads `kCheckFail`/`kCheckPending` from
  `pr_state_style.dart` rather than re-typing the literals; `landed` uses `cs.prMergedText` (the
  AA-safe purple) because a tone tints text as well as the dot. Guarded by a test.
- **Stale** (SPEC-32 §7.5) dims only the *derived* half and appends `· last known` with the existing
  tooltip. The PR number never goes stale; SPEC-23's pill dimmed wholesale, hiding the one reliable fact.
- **Truncation, not reflow.** The sentence elides with an ellipsis; the composer's width is not
  negotiable and a bar that reflows as CI churns is worse than one that elides.
- **On the composer's top edge**, inside its box and above a 1px hairline (`onSurface` at 7%) —
  see decision D11. The bar owns no insets of its own; `Composer.header` supplies them.
- **Text separators and the `+n more` underline read `cs.outline`, never `cs.outlineVariant`.** The
  latter is the *hairline* token: at 1.07:1 on `surfaceContainerHigh` the `·` was not on screen at all
  and the dotted underline — the only thing that says `+2 more` is tappable — was invisible in both
  themes. The mockup gives separators their own mid-grey (§3).
- **`attention` resolves its label colour per theme.** Only the light theme needs the darkened
  `statusCautionText` (`kCheckPending` is 2.1:1 there); on dark the label keeps the dot's own amber
  (7.1:1 on the surface, and better than the orange on every tint). Two ambers 6px apart read as two
  verdicts, which is the failure `prToneColor`'s docstring warns about.
- **The destructive direct CTA is `errorContainer`/`onErrorContainer`, not `kCheckFail`.** That red is
  the hue a failing build owns; painting "discard this worktree" in it made the one irreversible button
  out-shout the fact beside it. Same pairing on the confirm's commit button (§9).
- **An ended pull request's detail is a brief, not a to-do list**: `Landed` (the ending + `N checks
  passed`) then `Left behind` (the residue), and **no per-check list** — a merged PR's build is history,
  and twelve rows of it were the bulk of the scroll. Mockup §4's merged popover.
- **The residue is `PrResidue`**, and every number in it is already in the repos snapshot — nothing new
  is fetched. `sessions` is the worktree's own `sessionIds.length` (what a wrap-up would archive);
  `baseBranch`/`baseBehind` are the **primary checkout's** branch and `behindCount`, which the server
  derives as `HEAD..@{upstream}` there — that is exactly the mockup's `main is 6 commits behind`.
  Reported for ended states only: while a PR is open, "a session is running in it" is not a fact about
  the pull request, it is how you are working on it. The primary checkout is never reported against
  itself. `merged 2h ago` stays unbuilt — relative time is not in the PR DTO (§8 records that).
  The fact reads `N sessions to archive`, not the mockup's `still running`: the set is every session
  bound to the worktree — idle, awaiting and exited included — and a wrap-up archives all of them, so
  "running" would be false for most and "to archive" is exactly what is about to happen (D23).
- **Only the ending is `landed`.** The residue is `quiet`: painting `2 files uncommitted` purple said
  the uncommitted work had merged. The `N checks passed` line takes the check glyph in `kCheckPass`
  rather than a tone dot — it is the one row in the brief that reports the build.
- **The snapshot is re-derived when a turn ends, and when a branch ref moves.** The bar asserts a
  *count* and offers a button to clear it, and `uncommittedFiles`/`aheadCount` come from the repos
  snapshot — which was recomputed only on connect, spawn, kill, pull-to-refresh and worktree
  add/remove. None of those covers the case the feature exists for: an agent committing mid-turn. The
  bar went on offering `Commit & push` for files it had already committed and pushed until the client
  reconnected. Two triggers now cover it (D22), both coalesced, because `listRepos` is a full git pass
  per worktree.
- **A verdict with no checks says why.** `checkRollup != 'none'` with an empty `checks` list is a shed
  lookup (SPEC-32 drops the second call under quota), so the detail prints `kShedChecksNote` instead of
  an unexplained gap — which is also why the fact reads `CI failing` rather than a count.

### 8.1 The dot reports the pull request, not the loud fact (normative)

`PrDot`, derived in `prStatus()` and painted by `prDotColor`. Precedence, top down — the mockup's §2
legend:

| # | Condition | Dot | Colour |
| --- | --- | --- | --- |
| 1 | no PR **and** no signal carries a remedy | `none` — a hollow ring | `cs.outline`, tone-independent |
| 2 | `isDraft`, or `CLOSED` | `muted` | `cs.outline` |
| 3 | `MERGED` | `landed` | `cs.prMergedText` |
| — | a PR in a state this derivation does not recognise (short-circuits rows 4–6, which all read the open PR) | `tone` — deferring to the loud fact, which reads `PR state unknown` when there is nothing else to report (D19) | `prToneColor(tone)` |
| 4 | any check `pending`, **or** `checkRollup: pending` with its list shed (D18) | `pending` — an arc, `checkProgress` round; a solid disc when the list was shed, since there is no count to draw | `kCheckPending` on a `cs.outlineVariant` track |
| 5 | `checkRollup: fail` | `fail` | `kCheckFail` |
| 6 | `checkRollup: pass` **and the loud fact is `quiet`** | `pass` | `kCheckPass` |
| 7 | otherwise | `tone` | `prToneColor(tone)` |

Row 6's second clause is load-bearing: **green means *nothing needs you***, not "the build is fine,
look elsewhere for the problem". Without it a PR with conflicts, a moved base, open review threads,
unpushed commits or a stale local branch drew the same green disc as one that was ready to merge, and
the only ambient graphic in the pane contradicted the sentence beside it. Rows 4 and 5 are checked
first, so a red or in-flight build still outranks a louder amber fact — which is the case §8.1 was
written for. The pass verdict is reachable only from the all-clear (§5 rows 10–11) and only with a
green rollup: `ready to merge`, `N checks passed`, and `green and up to date` — the last being that same
green PR when the count was shed or the merge is `BLOCKED`. `ready for a PR` and `clean` have no rollup
to report and fall to row 1's ring. See D17.

A **separate derivation from `tone`**, because the two make different claims and §4's earlier
"tone — the dot's hue" made them one. Two consequences of collapsing them, both wrong on screen:

- **A green PR's dot was grey.** The all-clear fact (`12 checks passed`) is `quiet` by §5 row 11, and
  `prToneColor(quiet)` is `cs.outline`. The legend says solid pass.
- **A red build's dot went amber** as soon as a local commit outranked it (§5 row 3 before row 5). The
  sentence *should* lead with the unpushed commit — you cannot fix CI for commits the remote has never
  seen — but the build is still red, and the dot is where that gets reported.

Row 1 is `isQuiet`'s predicate, not `!hasPr`: the ring means *nothing to report*, so a branch with three
uncommitted files and no PR is row 7 (a solid disc in its fact's hue), matching the mockup's `dirty`
picture. Row 2 sits above rows 4–6 because §5 mutes a draft's own facts — the one graphic must not
shout what the sentence deliberately keeps quiet.

**One mockup picture disagreed:** `hot` (1 unpushed + CI red + 3 threads) drew an amber dot. That is a
leftover — the mockup's own §8 records that this state's loud fact was corrected from `2 checks failing`
to `1 commit unpushed`, which flipped its tone-driven dot from red to amber as a side effect. The legend
and this table are the rule.

## 9 · Non-goals

- Rebase/merge-commit strategies. Squash only, matching this project's own merge habit.
- Auto-tidying after a merge (`--delete-branch`), for the reason in §6.1.
- Reverting a merge, editing PR metadata, requesting reviewers.
- Any A- or C-direction affordance: per-fact segments in the bar, the landing gauge.
- Making the magic Fix's problem list user-editable.

### Requires

`gh` **≥ 2.40** for `pr update-branch`. No preflight probe: `mutatePr` already surfaces gh's own
stderr, so an older CLI reports `unknown command: update-branch` — the correct diagnosis, arrived at
without spending a subprocess per call to pre-empt it. The other two verbs (`pr ready`,
`pr merge --squash`) have been available far longer.

## 10 · Testing

- **Rules live in unit tests.** `pr_signals_test.dart` pins precedence, labels, tones, `isQuiet`,
  `needsConfirm`, check-progress and the magic-Fix threshold — no widgets. Widget tests then only have
  to prove the rules are *rendered*.
- **Server:** `git.test.ts` covers `syncBaseBranch` against a real bare-`origin` fixture, including
  the fast-forward refusal; `manager.test.ts` covers composition and guards with a gateway stub.
- **Wire:** the keyless stub loop (`test/e2e-server.ts --mode stub`) is the acceptance gate for every
  new `CmdKind`; unit tests do not prove routing.
- **Not asserted in widget tests:** that a non-confirming op skips its dialog. Observing the *absence*
  of a dialog requires a live connection (the store's request leaves a pending timer). That rule is
  pinned on `needsConfirm` instead.

## 11 · Gaps found and closed

**G1 — the confirm dialog never says it deletes the branch.** The step is guarded by
`status.hasPr ? null : status.identity`, but these ops only run when there *is* a PR, so the identity
is `#142`, the guard yields null, and the line is dead code. Wrap up *does* delete the branch (§6.1
step 3) and never admits it. The bar test asserts the other three steps, so this slipped through.

**G2 — Discard worktree leaves the branch behind.** Wrap up deletes it; Discard runs only
`worktree.remove`. A closed PR's branch survives while a merged one's does not, and the dialog's
"Remove what it left behind" over-promises. **Resolution: Discard also deletes the branch** (see
plan T7.2 and decision D9).

**G3 — `runPrRemedy` reads `storeControllerProvider` directly**, so a test cannot observe that a
non-confirming op skips its dialog: dispatch returns a future that never completes without a live
connection, leaving a pending timer. This is a DIP violation, and §10's admitted testing gap is its
symptom rather than an inherent limit. **Resolution: inject the executor** (plan T7.3).

**G4 — the "will be lost" warning is inferred by string-matching a display label**
(`s.label.contains('uncommitted')`). Rewording a label would silently delete a data-loss warning, and
because the labels are pinned *as strings* the tests would not catch it. Same root cause as G1.
**Resolution: carry the count structurally** (plan T7.4).

### Found by the phase-8 review passes, all closed

| # | Gap | Resolution |
| --- | --- | --- |
| G5 | The home sheet rendered prompt remedies into a no-op callback — a dead button with no feedback (found independently by all three reviewers) | `canInsertPrompt` (§4) |
| G6 | Magic `Fix` was offered while a direct op was outstanding, so "fix everything" could leave `Update branch` undone | the second clause in §5's magic rule |
| G7 | The magic CTA copied `loud.tone`, bypassing tone promotion | both CTA paths now share one promoted-tone expression |
| G8 | The confirm listed the branch deletion *before* session reconciliation; the server does the reverse | dialog reordered to match §6.1 |
| G9 | The pinned CTA claimed "Asks first" for the two ops that deliberately do not | copy derived from `needsConfirm(op)` |
| G10 | `ref.read` and the messenger were used after the confirm `await` with no mounted guard | the runner is resolved before the await; `context.mounted` checked after |
| G11 | `deleteBranch` throwing after the worktree was already gone made wrap-up/discard non-retryable and skipped the snapshot broadcast | the branch leg is now best-effort and reported (`branchReason`), like the base sync |
| G12 | `syncBaseBranch` silently picked one checkout when a branch was checked out in several, leaving the others stale | refuses unless exactly one worktree hosts the branch |
| G13 | A PR lookup already in flight could re-seed the cache *after* a mutation invalidated it, undoing §7's guarantee | per-key generation counter; an in-flight lookup does not cache if the generation moved |

## 11a · Accepted limitations

**L1 — the ops trust the client's view of PR state.** `wrapUpWorktree`/`discardWorktree` act on the
worktree without re-checking GitHub, so a PR reopened within one poll interval (~10–60s) could still be
offered "Discard".

A fresh server-side lookup before acting was considered and **rejected**: under SPEC-32's quota ladder
it can return `unknown`, and refusing then would make tidying up impossible exactly when the user most
wants it — trading a rare, recoverable, warned-about mistake for a frequent hard block during PR-heavy
work.

Mitigations, in order of strength:
1. **The confirm dialog names what it will destroy** — the worktree path, the branch, and any
   uncommitted file count.
2. **A stale snapshot is declared.** When `PullRequest.stale` is set (SPEC-32 shed the refresh), the
   dialog adds a warning line: *"Its state could not be refreshed (GitHub quota), so this may already
   be out of date."* It warns and still permits — blocking would recreate the failure this limitation
   exists to avoid.
3. **The damage is mostly recoverable.** A PR necessarily has a pushed head, so `origin/<branch>`
   retains the commits, and `worktree.createFromPr` rebuilds the worktree. Live sessions are archived
   rather than killed, so transcripts and resume handles survive. **Uncommitted files in the removed
   worktree are the one unrecoverable loss**, which is why the dialog counts them explicitly.

**L2 — the base sync assumes `origin` owns the base branch.** In a fork workflow where `origin` is the
fork and the PR targets an upstream repo, `git fetch origin <base>` fetches the fork's copy. Carrying
the base *repository* identity through `PrLookup` is out of scope; makit creates worktrees in the
user's own repo, and "fast-forward to `origin/<base>`" is what a tool operating on `origin` should do.

**L3 — `expectBranch` pins the branch, not the commit.** The guard refuses when the worktree has moved
to a *different* branch since the confirm (D10), but a commit made on the *same* branch between the
confirm and the click is still deleted by `git branch -D` — unpushed, that commit is gone. Sending the
expected HEAD oid alongside the branch was considered and **rejected**: no oid exists anywhere in the
pipeline today, so it means a `rev-parse` per worktree on the repo-list hot path, a new DTO field, and
plumbing through four layers — to cover the seconds a dialog is open, and at the cost of a refusal the
user can only clear by reconfirming. The branch the dialog *named* is the irreversible half, and that
is guarded; this residue is one commit on a branch whose pushed history `origin/<branch>` still holds.

## 12 · Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | B1 (disclosure), not B2 (full sentence) | B2's sentence truncated at composer width, and its dimmed tail was not tappable — it informed without helping |
| D2 | The CTA **rests** when nothing is pressing | SPEC-23 fell back to the last-picked action, offering Pull with nothing to pull |
| D3 | Inapplicable prompts stay **listed and disabled with a reason** | Same convention `worktree_actions.dart` already uses for a blocked Rename; absence of an action must not read as a missing feature |
| D4 | Magic Fix takes the CTA at ≥2 problems | With several problems that *is* the one next step; at 1 it would be a vaguer label for the same thing |
| D5 | Merge does not tidy up | §6.1 — sessions would lose their worktree mid-run |
| D6 | `isQuiet` ignores the CTA | A chip on every clean branch added a meta line to rows with nothing to report and made repo cards tall enough to push their own "Show less" off screen |
| D7 | One `PrDetailBody`, dialog on desktop / sheet on mobile | Let `pr_sheet.dart` be deleted rather than maintained in parallel; a hover popover cannot hold buttons |
| D9 | Discard worktree **does** delete the branch | Symmetry with the verb: "discard" that leaves the branch behind is not discarding. A closed PR necessarily had a pushed head, so `origin/<branch>` retains the commits and a local `-D` is recoverable by re-fetch — the earlier "silent loss" argument for keeping it was wrong. The confirm names the branch, so declining is available |
| D8 | `locateWorktree` replaces three per-field scans | Six independent scans could straddle a snapshot swap and describe two different worktrees |
| D10 | The dialog's branch travels with the command (`expectBranch`) and a mismatch is **refused** | The server resolves the branch again when it runs, so without it the user could confirm "delete feat/x" and have a branch they checked out since — possibly with unpushed commits — deleted by `git branch -D`, which does not ask |
| D11 | The bar sits **inside** the composer box, on its top edge above a hairline — not in its own floating row | The mockup's §5 second option, adopted after the first shipped. At this weight it reads as a caption on the box you are typing into, which is what it is: most of its actions put text there. A separate row spent full composer width on one sentence. `Composer.header` renders it regardless of `enabled`, and both composer instances (normal + free-text answer) get it — otherwise the worktree's only status line vanished for the length of an inline ask |
| D12 | `Fix` is the verb for **both** the CI prompt and the magic remedy | User preference over the mockup, which shortened only in the fact list (`Fix CI` in §4, `Fix` in §6). One verb source (`prRemedyLabel`) beats a per-surface table, and the two never collide in the bar — the sentence beside the button says whether one thing or three are wrong. They *do* co-occur on the mobile sheet (pinned `Fix` + the build row's `Fix`), which is the accepted cost |
| D13 | The CTA promotes a quiet tone to the **remedy's** tone, not always to `attention` | Keeps D-nothing-looks-disabled while restoring the colour language: `Squash & merge` is the landing action and landing is purple everywhere else in the pane. An amber merge button said `attention` about the one action that is good news |
| D14 | A **closed** PR's facts are `quiet`; only its button stays `blocking` | It is history, not an alarm — nothing is failing, the pull request simply ended (mockup §3 `closed`). The button still deletes a worktree and a branch, so it keeps the loud register |
| D15 | The detail is behind a collapsed disclosure **on the sheet only** | The point of the pinned CTA is that the sheet opens on the decision; facts plus twelve check rows above the fold undid it. The dialog has no pinned CTA, so it keeps showing everything |
| D16 | The home-row chip loses its capsule, and tones only the fact | The row already carries an accent bar and a branch name; a third filled element is the chrome B set out to remove. `#142` is the same number whatever CI says, so it keeps the row's ink — the desktop bar always did, and painting both made a green PR's number green |
| D17 | A green build reports `pass` **only while nothing is pressing** | The dot is the pane's one ambient graphic, so it has to answer "does this need me?", and `checkRollup: pass` alone answered a narrower question. Reverses the mockup's `oneProblem` picture (green dot over `1 commit unpushed`) deliberately: that picture and its `threads` picture — amber dot, same green build — could not both be right, and "green = nothing needs you" is the only version a user can learn. A failing or in-flight build still wins, so §8.1's founding case (red dot, amber sentence) is unchanged |
| D18 | A **shed** rollup still reports its verdict | `pending`/`fail` come from `checkRollup`, but the *count* comes from the check list, and SPEC-32 sheds the list under quota. Deriving "in flight" from the list alone made a running build indistinguishable from an all-clear — and the all-clear branch then offered `Squash & merge` on a build that had not finished. A countless `CI still running` and `PrDot.pending` now cover it; `checkProgress` stays null, so the dot is a solid disc rather than an arc claiming a count it does not have |
| D19 | An unrecognised PR state says so | `open` is null for any state but `OPEN`, and the all-clear branch read that as "no pull request" — so a PR whose state this derivation does not know printed `#142 · ready for a PR`, a contradiction in four words. It now reports `PR state unknown` and offers nothing |
| D20 | Residue belongs to a **secondary** worktree only | It is what a wrap-up or discard takes with it, and the primary checkout is never removed (the ending branch gives it no direct op at all). Its sessions are not going anywhere and its own branch cannot be "behind" itself, so `prStatusFor` gives it `const PrResidue()` |
| D21 | `PrFactLabel` is the one `#142 · fact` fragment | The home-row chip and the session subtitle chip drew it separately and had drifted the same way — both toned the whole string and bolded all of it, so a merged worktree's number read purple and a failing one's red while the bar kept it in the surface ink. One widget in `pr_tone.dart` now owns the split (identity `onSurface` w600 · separator `outline` at 55% · fact in its tone); the bar keeps its richer version (inline dot, stale suffix, larger ramp) |
| D22b | The fallback's re-walk is **keyed by directory** | It re-walks on every event so a new namespace (`git branch a/b/c`) gets its own watcher, and appending duplicated every directory it had already covered — each duplicate then re-walking in turn, so three commits took the set from 3 watchers to 66 and handled each event as many times over. Keyed by path it is idempotent: a re-walk adds only new ground, and a vanished directory is forgotten so a later walk can re-attach. `watcherCount()` exists for the test that holds it there |
| D22a | The `refs/heads` watch is **recursive** | Git stores `feature/foo` as a file in a *nested* directory, and `fs.watch` without `recursive: true` reports nothing for nested children on Linux or macOS — so a flat watch misses every slashed branch, which is every branch in this repo. Node supports `recursive` on macOS, Windows and Linux (≥ 20.13; this package requires ≥ 22.13). Where a platform refuses it, the watcher falls back to one watch per directory, re-walked when a namespace appears — and that path is held to the same regression test rather than merely existing |
| D22 | The repos snapshot is re-derived on **turn end** and on **`refs/heads` change** | The bar's count was only as fresh as the last connect. Turn end (`running` → anything, once per turn, trailing-throttled 1s) catches the agent's own commits — the reported failure. A watch on the *common* git dir's `refs/heads` catches a commit or branch move from any source, and because a branch ref lives in the common dir whichever worktree moved it, one watch covers every linked worktree. Deliberately **not** `index`/`index.lock`: git rewrites those throughout a turn, and each snapshot is a git pass per worktree. `HEAD` is watched too, for a checkout in the primary checkout |
| D23 | `WorktreeDTO.sessionIds` excludes **archived** sessions, and the residue fact says `to archive` | The field's own protocol doc always said it links the sessions bound to the worktree, but `listRepos` is handed `allSessions()`, which keeps archived ones — so their ids resolved to nothing in the two consumers that map this field to session rows, and the wrap-up brief counted them as work left behind. Filtered at source. The remaining set is still not "running" (idle, awaiting and exited are in it), and a wrap-up archives every one, so the fact names that instead |
| D24 | A prompt remedy types into the composer that is **mounted** | The bar is rendered by both composers (D11), but only one of them is on screen: a free-text ask replaces the message composer with the answer composer. Aimed at the per-session message controller, the insert wrote to a field that was not there — the user saw nothing, and the text surfaced later, when the ask resolved and that composer came back. It now follows the visible field on both surfaces. The answer field is not a persisted draft, so that path writes no `composerDraftsProvider` entry and does not take the pane's composer focus node, which is wired to the message composer alone |
