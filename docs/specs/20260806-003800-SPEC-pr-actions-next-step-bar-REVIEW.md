# SPEC-pr-actions-next-step-bar — review record

Spec: [`20260806-003800-SPEC-pr-actions-next-step-bar.md`](./20260806-003800-SPEC-pr-actions-next-step-bar.md)
Plan: [`20260806-003800-SPEC-pr-actions-next-step-bar-PLAN.md`](./20260806-003800-SPEC-pr-actions-next-step-bar-PLAN.md)

**Three rounds.** Round one reviewed the implementation; round two reviewed *the fixes round one
produced*, which were otherwise unreviewed — and found a blocker there. Round three did the same to
round two's fixes, and found that one of them had not closed what it claimed. Plus two passes over the
spec and plan before any of it.
Kept in the repo because the *rejections* are the part worth auditing later — a reader can see what was
considered and why it was declined, rather than wondering whether it was noticed at all. The raw
reviewer transcripts are not kept (`.piano/` is gitignored); every finding worth acting on is below.

| Pass | Tool | Model | Focus |
| --- | --- | --- | --- |
| Spec-A | subagent (reviewer) | opus | spec claims vs code, verified line by line |
| Spec-B | subagent (architect) | opus | design judgement, YAGNI/SOLID, plan sequencing |
| R1 / R1' / R1'' | `codex exec` | gpt-5.6-sol, high | code quality + correctness |
| R2 / R2' / R2'' | `codex exec` | gpt-5.6-sol, high | spec/plan adherence, TDD/SOLID/YAGNI/clean code |
| R3 / R3' / R3'' | `ocr` | claude-opus-4.6 (bedrock), high | code only (`ocr` reviews diffs, not markdown) |

## Findings from the spec/plan passes

| Finding | Outcome |
| --- | --- |
| §6.1's wrap-up sequence listed session reconciliation **before** the worktree removal; the server does the reverse | Fixed in the spec, the confirm dialog and the mockup |
| §5 cited the wrong inherited row numbers from SPEC-pr-status-and-actions | Fixed |
| `worktree.wrapUp`'s documented ack omitted `projectId`/`worktreePath` | Fixed |
| Plan T7.1 would not have compiled — it missed `runPrRemedy` as the hop that calls the dialog | Fixed |
| **T7.2's rationale was factually wrong**: it argued `git branch -D` on a closed PR risks silent loss, but a closed PR necessarily has a pushed head, so `origin/<branch>` retains the commits | Decision reversed — Discard now deletes the branch (spec D9) |
| `runPrRemedy` read `storeControllerProvider` directly — a DIP violation, and the cause of §10's admitted testing gap | Fixed with the injected `PrOpRunner` seam (G3) |
| The magic-Fix checklist should be documented as precedence-ordered | Stated in §6.2 and pinned by a test |
| One test count was stale (24 → 25) | Fixed |

## Findings from the code passes

### Accepted — behaviour

| # | Finding | Found by | Fix |
| --- | --- | --- | --- |
| F1 | Home sheet has no composer, yet prompt/magic remedies render and dispatch into a no-op — tap does nothing | R1, R2, **R3** | Thread `canInsertPrompt` into `PrDetailBody`; hide prompt-backed remedies and a prompt CTA when false |
| F2 | Magic "Fix" is offered when ≥2 *prompt* remedies exist even if another actionable signal needs a direct op — so "fix everything" leaves e.g. Update branch undone | R1 | Offer magic only when **every** actionable signal is prompt-backed |
| F3 | Magic CTA copies `loud.tone`, bypassing tone promotion — a draft with red CI + threads yields an inert-looking button | R2 | Promote in one place, used by both CTA paths |
| F4 | Confirm lists branch-delete *before* session archive; server does remove → sessions → branch | R2 | Reorder; assert all four relative positions |
| F5 | `_PinnedCta` says "Asks first" for every direct op, incl. the two that deliberately don't | R2 | Derive from `needsConfirm(op)` |
| F6 | `ref.read` + messenger used after the confirm `await` with no mounted guard; repo convention guards this | R1, **R3** | Capture the runner before awaiting; guard with `context.mounted` |
| F7 | `deleteBranch` throwing after the worktree is already gone makes wrap-up/discard non-retryable and skips the broadcast | R1 | Make the branch leg best-effort + reported, like the base sync |
| F8 | `syncBaseBranch` silently picks one checkout when a branch is checked out twice (`--ignore-other-worktrees`), leaving the other stale | R1 | Refuse unless exactly one worktree hosts the branch |
| F9 | An in-flight PR lookup can repopulate the cache after a mutation invalidates it | R2 | Generation-tag the cache; only store if the generation is unchanged |

### Accepted — maintainability / tests

| # | Finding | Found by |
| --- | --- | --- |
| F10 | `forced` is a misleading name — that fetch is deliberately *not* forced | R3 |
| F11 | `discardWorktree`/`wrapUpWorktree` duplicate the lookup+remove+delete preamble | R3 |
| F12 | `worktree.ts` comment describes wrapUp but sits above discard | R3 |
| F13 | `pr_detail` re-implements `hasPr` and detects "ended" by matching display strings | R3 |
| F14 | No test for `magicFixPrompt` (ordering, details, override) | R2 |
| F15 | `unresolvedUnknown` test uses `unresolved: 0`, so it passes even without the guard | R2 |
| F16 | `needsConfirm` group omits `squashMerge`; no closed-PR-on-primary test | R3 |
| F17 | No routing/ack test for the four new `CmdKind`s | R2 |
| F18 | `kPreferenceEntries` order does not match declaration order | R3 |
| F19 | `MagicRemedy` never appears on `PrSignal.remedy`, only on `PrCta` — an implicit invariant. Documented **and** pinned by a test that also proves it reaches the magic path | spec review |

### Rejected

| Finding | Found by | Why |
| --- | --- | --- |
| **BLOCKER:** wrapUp/discard should re-verify PR state server-side before acting | R1 | Disproportionate, and the proposed fix is worse: a fresh `gh` lookup can return `unknown` under SPEC-github-gateway-and-budget's quota ladder, which would make tidying up **impossible** exactly when the user most wants it. The window is one poll interval; the action is behind a confirm that names the worktree and branch; and a PR necessarily has a pushed head, so `origin/<branch>` retains the commits. Recorded as limitation §11a L1, **with a cheap mitigation added**: the confirm now declares a stale (unrefreshable) snapshot instead of asserting the PR state as fact. It warns rather than blocks, for the same reason the full fix was rejected. |
| Fork workflows: `origin` may not own the PR's base branch | R1 | Real but out of scope — makit creates worktrees in the user's own repo. Fixing it means plumbing the base *repository* identity through `PrLookup`. Recorded as a spec non-goal; the current behaviour ("fast-forward to `origin/<base>`") is what a tool operating on `origin` should do. |
| Extract `prRemedyLabel`/`prRemedyIcon` into `pr_remedy.dart` | spec review | Low value; ~500-line file is cohesive and the churn touches 6 imports. |
| Cut `Mark ready` / `Update branch` as YAGNI | spec review | Explicitly approved by the user after being flagged as speculative; provenance recorded in spec §6.4. |

## Round two — reviewing round one's fixes

The fixes from round one had never been reviewed, which is exactly where the next bug was.

### Accepted — behaviour

| # | Finding | Found by | Fix |
| --- | --- | --- | --- |
| **G14** | **BLOCKER.** The confirm names the branch from the app's snapshot, but the server resolves the branch again when it runs. Check out a different branch in that worktree in between and `git branch -D` takes the *new* one — unwarned, and unrecoverable if unpushed | R1' | `expectBranch` is sent with the command and refused on mismatch, before anything is removed |
| G15 | **G11 was not actually closed.** The server reported `branchReason`; the app dropped it, so a failed branch deletion still reported "Removed feat/x" | R1', R2' | Decoded into `WrapUpReport.branchReason`; `summary` says `branch kept` and `detail` feeds the "Why?" action |
| G16 | A mutation invalidated only `pr:<repo>:<branch>`, not `openPrs:<repo>:*` — so the "New worktree from PR" picker could keep offering a squash-merged PR (checkout then fails) or show a ready PR as a draft | R1' | Every `openPrs` key for the repo is invalidated, and its writer is generation-guarded too |
| G17 | `ScaffoldMessenger` retained across an await and used without a `mounted` check, in two places | R1' | Guarded |
| G18 | `hasPr` still inferred domain state from `identity.startsWith('#')`, and `#42` is a legal branch name — such a branch was classified as a PR, hiding "Create PR" from it | R1' | Explicit `hasPr` field from `pr != null`; `endedState`/`isEnded` collapsed to one field |

| G24 | The detail sheet **outlives the widget that opened it** — a repos snapshot can drop the worktree row while its sheet is up. `runPrRemedy` guarded disposal *during* the confirm await, but not *before* the callback ran, so `ScaffoldMessenger.of(context)` and `ref.read` could both fire on a defunct element | R3' | `context.mounted` checked at entry, before anything touches `ref` or `context` |

| G25 | `syncBaseBranch`'s `fetch`/`merge` ran under the 15s **read** cap, though the file's own comment says mutations are deliberately uncapped. A merely slow fetch on a large repo was reported as `could not fetch origin/<base>` | R3' | Those two legs use the uncapped `run`; the cheap local `rev-list` keeps the cap |
| G26 | `PrCtaButton.onInsertPrompt` was dead — an orphan of the round-one refactor, since every action now flows through `onRun` | R3' | Removed |

### Accepted — documentation and tests

| # | Finding | Found by |
| --- | --- | --- |
| G19 | Two of round one's tests were behaviour-insensitive: the step-order test checked only one pair of four, and the "survives a label reword" test never reworded anything, so the old string-matching implementation would have passed it | R2' |
| G20 | Spec §6.1's "steps 1–3 throw" became false the moment G11 made the branch leg best-effort; the manager's own doc comment repeated it | R2' |
| G21 | The as-built mockup was stale in three further passages: the mobile sheet's wrap-up list still said *stop sessions → remove worktree*, the confirm count said two ops ask (it is three), and the magic-Fix condition omitted its second clause | R2' |
| G22 | Stale doc counts (56/25/19, 1751) and the Scope block said four `CmdKind`s where the code adds five | R2' |
| G23 | The gateway generation guard had no committed test | R2' |
| G27 | The `worktree.discard` handler's comment still described `wrapUp` (base branch, `baseBranch` param). A round-one fix for exactly this had silently failed to match and was never verified | R3' |

### Rejected in round two

| Finding | Found by | Why |
| --- | --- | --- |
| `wrap_up.dart` has no dedicated test file | R3' | Its control flow *is* covered, through the widget, by `pr_bar_test.dart`'s confirm / no-confirm / cancel / dispatch cases — which is the seam `PrOpRunner` was built for. The one uncovered path is "the messenger was disposed mid-flight"; a test for that would have to tear down the tree during an await and would be more fragile than the two-line guard it protects. |
| `PrComposerBar.onInsertPrompt` is dead | R3' | False positive — it is used at `pr_bar.dart:92` and `:118`. Only `PrCtaButton`'s copy was dead (G26), which the same pass also found. |
| Re-check the uncommitted-file count before removing | R1' | The branch guard (G14) covers the irreversible half. `--force` removal is the documented behaviour and the dialog already warns files will be lost; re-counting would add a second failure mode for a warning the user has already accepted. |

### Verification of a fix rather than assertion of it

G13's generation guard was the one round-two finding I could check mechanically: the new race test was
run against a build with the guard removed, and it failed — so it pins the behaviour rather than merely
passing alongside it.

G14's guard was verified over the wire rather than reasoned about: against a worktree deliberately
switched to another branch, a stale `expectBranch` is refused
(`worktree is on feat/switched-away, not feat/landed — refresh and try again`) with nothing removed,
while the correct expectation proceeds and deletes the branch that is actually there.

## Round three — reviewing round two's fixes

Same rule again: round two's fixes had never been reviewed. One of them turned out not to have closed
what it claimed, and the round's most consequential finding came from neither reviewer but from running
the formatter.

### Accepted — behaviour

| # | Finding | Found by | Fix |
| --- | --- | --- | --- |
| **H1** | **`dart format` had never been run.** Twelve of the feature's own files were unformatted, and `flutter-ci.yml` runs `dart format --output=none --set-exit-if-changed lib test` tree-wide — so the branch would have failed CI on a step no reviewer can see | running it | Formatted; the gate is now named in the plan's definition of done |
| H2 | **The generation guard missed a cold `openPrs`.** While the first list for a repo is in flight its key is in neither `cache` nor `generation`, so the mutation's wildcard sweep bumped nothing — and the pre-mutation list then seeded the cache the mutation had just emptied, for a full TTL | R1'' (and independently while reading) | The `openPrs` generation is now **per repo**, not per cache key, so a list nobody has named yet is still covered |
| H3 | **Not caching the stale answer was only half the guard.** A caller arriving *after* the mutation still joined the in-flight pre-mutation promise and was handed that state directly — and the repos broadcast the mutation itself triggers is exactly such a caller | R1'' | `invalidate` drops the matching in-flight registrations, so the next caller starts its own lookup; `dedupe`'s cleanup is now identity-checked so the old promise cannot evict the new one |
| **H4** | **G18 was not actually closed.** Two consumers still read `identity.startsWith('#')` — `pr_bar.dart`'s dot and `repo_chips.dart`'s label — so a branch literally named `#42` was drawn with a filled (has-a-PR) dot and had its name repeated beside the row that already showed it | R1'', R2'', **R3''** | Both read `status.hasPr`; two regression tests use `#42` as a branch name |
| H5 | **Stale dimmed the PR number**, which spec §8, the review record and the function's own comment all forbid. The test that claimed to pin it only asserted the text was present | R2'' | The identity span is no longer dimmed; the test now asserts the *alpha* of the identity and of the derived fact |
| H6 | "Create PR" was keyed off `open == null` — the *recognised* state — not off the PR. A PR in any state this derivation does not model left `open` null while `hasPr` was true, so the button offered to open a second pull request while the menu hid the same entry as meaningless | **R3''** | Keyed off `pr == null` |
| H7 | `PrToneDot`'s disc (9px) and arc (11px) sized the widget differently, so the sentence twitched 2px sideways the moment a build finished — in a bar whose stated contract is "truncation, not reflow" | **R3''** | Both forms occupy the ring's box; pinned by a size-equality test |

### Accepted — maintainability, tests and docs

| # | Finding | Found by |
| --- | --- | --- |
| H8 | The widget-level `unresolvedUnknown` test used the helper's default of `0`, so it passed without the guard — the same defect as F15, in a different file. Now uses a positive count, with a control proving the count *is* reported when known | R2'' |
| H9 | The two "primary checkout is never offered a wrap up / discard" tests asserted `_op(remedy)`, which reads null for a `PromptRemedy` too — so an offered prompt would have passed them | **R3''** |
| H10 | The round-one rewrite deleted the only test of `openPrUrl`'s failure path, and no other test replaced it. Restored | **R3''** |
| H11 | `_pumpSheet`'s `overrides` parameter was orphaned when its one test moved to `magic_fix_prompt_test.dart` | **R3''** |
| H12 | `_whyNot` was typed `String?` but can never return null, which made `_PromptMenuItem`'s `reason != null` branch dead | **R3''** |
| H13 | Three stale comments: `PrDirectOp`'s doc named two confirmed ops (there are three) and referenced a non-existent `isDestructive`; `wrap_up.dart`'s library doc said "two kinds of action" for three; `mutatePr`'s said "both verbs" for three | **R3''**, R2'' |
| H14 | Spec §6.2 claimed `still a draft` is the only quiet fact carrying a remedy. `ready to merge` is another, and a draft mutes its *own* failing build and open threads — which is most of why the promotion exists | R2'' |

### Mockup (`mockups/pr-actions-next-step.html`)

The page's §8 records where the original mock turned out to be wrong. Round three found that the
pictures above it still showed the *mock*, which §8's own lede says is the thing to avoid — a reader
trusts the picture over the prose. The pictures now show as-built, and §8 grew from six rows to nine.

| Finding | Found by | Fix |
| --- | --- | --- |
| The flagship three-problem state led with `2 checks failing`, but precedence puts **unpushed commits above a red build** — so every picture of it on the page named the wrong loud fact, in the wrong colour | reading §5 against the model | `st.hot` now leads with `1 commit unpushed` in amber; recorded as a new §8 row |
| The mobile home row continued the sentence with a second fact; the shipped chip is `identity · loud fact` and nothing more, and carries no chip at all when the state is quiet | R2'' | `mrow` matches the widget; two new §8 rows |
| The merged sheet invented `Merged 2h ago` and `main is 6 commits behind`, and listed wrap-up's four steps under the button — those belong to the confirm | R2'' | Both corrected; the hero shows the loud fact alone |
| "§9 · The two confirms" — there are three | R2'' | Retitled and the lede names them |
| Wrap up's note said only step 4 is best-effort (steps 3 *and* 4 are) and omitted `branchReason` from the ack | R2'' | Corrected |

### Rejected in round three

| Finding | Found by | Why |
| --- | --- | --- |
| **BLOCKER:** `expectBranch` compares only the name — send the expected HEAD oid too, or a commit made between the confirm and the click is deleted by `git branch -D` | R1'' | Real but disproportionate. No oid exists anywhere in the pipeline: closing it means a `rev-parse` per worktree on the repo-list hot path, a new DTO field, and plumbing it through four layers, to cover a window measured in the seconds a dialog is open. It also adds a failure mode — a refusal the user can only clear by reconfirming. The irreversible half (the *wrong branch* being deleted) is what G14 closed; this is the same branch, one commit further on, and one whose pushed history `origin/<branch>` still holds. Recorded as a limitation. |
| **BLOCKER:** a detached-HEAD worktree sends no `expectBranch`, so the guard is skipped and a branch checked out in the meantime is deleted unwarned | R1'' | ~~Not reachable from this app.~~ **Superseded — see C7.** The unreachability argument was sound (both ops derive from a PR, and a PR lookup is keyed by branch) but a third reviewer found it independently in round four, at which point defending the analysis cost more than the three-line guard. `runPrRemedy` now refuses a branch-deleting op with no branch. |
| `syncBaseBranch` fetches twice on the not-checked-out path; replace the second with `update-ref` after an `--is-ancestor` check | **R3''** | `fetch origin <b>:<b>` already refuses a non-fast-forward, in one command, using git's own rule. The proposal reimplements that rule in two commands to save a ref advertisement on an op that just deleted a worktree. |
| The `generation` map grows without bound | **R3''** | One entry per branch ever mutated, per repo, per process — bounded by the branches a user actually acts on, and each entry is a string and a number. Pruning it means deciding when a generation is safe to forget, which is exactly the question the counter exists to avoid. |
| Extract the shared `project → repoPath → listWorktrees → find` preamble out of `_removeWorktreeAndBranch` and `_mutatePr` | **R3''** | The two want different things from it (a nullable branch and a refusal, versus a required worktree and a different message), so the helper would return a bag both callers then re-validate. |
| `createPr` is hidden from the menu rather than shown disabled, against the docstring's "explain the block, don't hide it" | **R3''** | The convention is about actions that *could* apply later. "Create PR" on a branch that has one is not blocked, it is meaningless — and the comment above the filter says so. |
| `_whyNot` should say "no pull request yet" for PR-dependent actions on a PR-less branch | **R3''** | Fair, but the phrasings are already true of a PR-less branch (there is no failing build, there are no threads), and reaching that state means the menu is open on a branch whose CTA is "Create PR". Not worth six new strings. |
| `190` in `repo_chips.dart` should be a named constant; a `../../` import sits after the local ones; a `Builder` gives no rebuild isolation; two nits about indentation | **R3'' / R3''** | Style preferences with no behavioural consequence; `dart format` governs the layout ones. |
| `needsConfirm`'s test should iterate `PrDirectOp.values` to force a new op to be classified | **R3''** | The switch is exhaustive at compile time, so a new op cannot be added without classifying it. A test that calls `needsConfirm` for every value and asserts nothing would add a line of coverage and no signal. |

### Verified rather than asserted

H2 and H3 were each written as a failing test first and watched fail for the right reason: the cold-list
test cached the pre-mutation list and served it back, and the post-mutation caller received the in-flight
answer without a second `gh` call. H4, H5 and H7 likewise — the `#42` branch drew a filled dot, the
number came back with alpha `0.55`, and the dot measured 9px against the arc's 11px.

## Round four — CodeRabbit, on the pull request

Twenty inline comments on [#138](https://github.com/leduckhc/makit/pull/138). Three were marked Major
and two of those were real; a third Major was a false positive whose *suggested hardening* was worth
taking anyway. The round's best finding was a genuine accessibility bug that the earlier rounds, all
three of them, had walked straight past — because none of them measured anything.

### Accepted — behaviour

| # | Finding | Fix |
| --- | --- | --- |
| **C1** | **`_mutatePr` looked its PR up non-interactively.** `findOpenPr` collapses `unknown` to null, so a lookup shed below SPEC-github-gateway-and-budget's reserve made "Mark ready" / "Update branch" / "Squash & merge" fail with `no pull request for feat/x` — for a PR plainly on screen — exactly when the account is throttled. These are button presses; the reserve exists for them | `interactive` threaded through `findOpenPr`; five existing tests failed the moment the stub started shedding background lookups, which is how thoroughly it was unguarded |
| **C2** | **Mutations inherited the 5s *read* timeout.** A slow `gh pr merge --squash` was reported as failed while GitHub applied it anyway — and `mutatePr` skips its cache invalidation on failure, so the UI then insisted on the pre-mutation state for a full TTL. The generation guards, defeated by a timeout | `PR_MUTATION_TIMEOUT_MS` (60s) for the three writes; the read cap stays where it belongs |
| **C3** | **Tone colours failed WCAG AA as text.** `prToneColor` returns dot/wash tokens, and the bar, the chips and the CTAs all printed *labels* in them: on the light theme `kCheckPending` is **2.42:1** and `kCheckFail` **3.21:1**. The filled CTA was worse than it looked too — `cs.onError` on `kCheckFail` is 3.35:1 | `prToneTextColor` (AA-safe label variants, 5.1–6.7:1) and `onPrToneFill` (measures both scheme inks against the actual fill), mirroring the `color`/`textColor` split `prStateStyle` already makes. Three new contrast tests |
| C4 | `openPrUrl` ignored `launchUrl`'s return value. It reports "nobody handled this" by returning **false**, not by throwing, so a platform with no handler left the tap doing nothing | Result checked; a fake `UrlLauncherPlatform` reaches the path (with no plugin registered the call throws instead, which the old test already covered) |
| C5 | The worktree starter passed no `fallbackBranch`, so in its *common* state — the snapshot not yet carrying the worktree it just created — the bar read `detached`, the confirm could name no branch, and no `expectBranch` was sent | Both take `widget.worktree.branch`, as `desktop_chat_pane.dart` already did |
| C6 | `_whyNot` gave the secondary-branch reason for "Create PR" on the primary checkout: *"this branch has no commits to open a PR with"*, when no commit would ever change the answer | `PrStatus.isPrimary` carried through; the menu explains the actual block (D3) |
| **C7** | **A branch-deleting op with no known branch.** Raised by codex in round three as well, and rejected twice as unreachable — the third reviewer to find it. The reasoning still holds, but "unreachable" is a claim about the whole call graph that a reader has to re-derive; a refusal at the dispatch point is three lines and needs no such argument | `deletesBranch(op)` + a refusal in `runPrRemedy`, with a widget test |

### Accepted — tests and docs

| # | Finding |
| --- | --- |
| C8 | Two `expect(find.text('1 PR'), findsNothing)` assertions could never fail — no widget renders that string, so both passed whether or not an ended PR was counted as open. Now assert on the `openPrCount` key |
| C9 | A test named *"it needs no confirm"* only asserted a label. The invariant it names is now pinned too |
| C10 | The precedence docstring listed six signal kinds; the code emits seven — `mergeStateStatus: BEHIND` was missing, in the docstring the ordering tests treat as their contract |
| C11 | The `openPrs` cache test assumed its first two calls were cached without asserting it. (The Major claim attached to this — that the stub feeds `openPrs` an object instead of a list — is wrong: `PR_JSON` *is* a JSON array, and a probe confirmed the second call was served from cache. The assertion is still worth having) |
| C12 | The plan said Phase 7 was remaining work six lines above the chart marking it done; the spec's status line advertised "2 known gaps, see §11" against a §11 titled *Gaps found and closed* — it meant §11a's limitations |
| C13 | Two REVIEW.md tables carried a stray fourth cell (MD056), and a fence had no language (MD040) |
| C14 | The `gh` version floor for `pr update-branch` (≥ 2.40) was undocumented |
| C15 | The mockup's dot shifted 2px between its 9px disc and 11px ring — the same defect as H7, in the CSS rather than the widget, and missed when H7 was fixed |
| C16 | §9 of the mockup was retitled "the three confirms" in round three but the third card was never added — a fix that changed the heading and not the thing it described |

### Rejected

| Finding | Why |
| --- | --- |
| Raise the tone-tinted chip labels to 4.5:1 | Measured at every alpha from 4% to 20%: the worst pair sits at **3.85:1 even at 4%**, because the shortfall comes from `surfaceContainerHigh` rather than from the tint. Reaching AA needs a darker text token per tone per theme — a palette decision, not a review fix. A test now pins the 3:1 floor it does hold so it cannot drift while that is decided, and the finding is raised in the PR rather than silently designed around |
| Make `IconGlyph.font(...)` const in `agents_chat_section.dart` | It already is: the argument sits inside a `const _PrPromptRow(...)` invocation, where const is implicit |

### Round four, part two — auditing my own fixes

The instruction that produced this section was *"no nit can be left unresolved"*, which turned out to
be the right pressure to apply: re-checking the round-four fixes the way the rounds check everything
else found two of them **untested**, in exactly the way this document has criticised four times.

| # | What was wrong with the fix | Now |
| --- | --- | --- |
| **C5′** | The C5 tests asserted `prStatusFor`'s *own* contract, which already accepted `fallbackBranch` — the bug was the **caller**. Reverting the fix left every test green. A test that cannot fail is a claim, not a check | `worktree_starter_pr_bar_test.dart`: the starter with an empty snapshot must name its branch, plus a control proving the snapshot still wins when it arrives. Verified by revert — it reports `detached · ready for a PR` |
| **C6′** | Same defect: the test asserted `PrStatus.isPrimary` was *carried*, not that the menu's reason changed. Reverting `_whyNot` left it green | Two widget tests on the rendered reason (primary vs secondary), the second existing only so the first cannot pass on a menu that gives every branch the primary reason. Verified by revert |
| C8′ | The `openPrCount` assertions needed proving too, since the string they replaced was vacuous | Verified by widening `openPrCount` to count *any* PR: both ended-PR tests fail. It now guards the regression it names |

Every other round-four fix was already written test-first and watched fail; C1's went further — five
pre-existing tests failed the moment the gateway stub started shedding background lookups.

### Round four, part three — the nits, none left standing

Everything earlier rounds waved off as style, now either fixed or refused **in writing**. The reason
this is worth doing at all: "rejected as a nit" and "forgotten" look identical six months later.

| Nit | Round | Outcome |
| --- | --- | --- |
| `desktop_chat_pane.dart`'s `../../` import sat after the local block | R3'' | Fixed |
| ...and its `Builder` bought no rebuild isolation — `ref.watch` registers against the enclosing `ConsumerState` wherever it is called, so it only scoped a name | R3'' | Replaced with a local `at`, and the comment now says why a `Builder` would be pointless here |
| `190` / `220` chip widths were bare magic numbers | R3'' | Named constants, each with the reason for *that* number (the home row has an age column to protect; the session subtitle does not) |
| `buildPrActionMenu`'s docstring promised "visible but disabled with the reason" while hiding `createPr` | R3'' | Documented as the one exception, with the distinction: the convention covers actions that *could* apply later, and this one never can |
| `_whyNot`'s reasons read oddly on a PR-less branch — "the build is not failing" when there is no build | R3'' | Branches on `hasPr` for the two PR-dependent actions; two tests, one of them the control |
| `needsConfirm`'s tests name each op individually, so a *new* op slips past them | R3'' | Fixed properly: the set assertions alone did **not** catch an op added as `false` (verified by adding a sixth), so a `hasLength` tripwire carries the check, with the reason string telling the next author what to decide. `deletesBranch` is pinned the same way |
| The `generation` map is never pruned | R3'' | Refused, with the bound stated in the code: one string/number pair per branch the user has pressed a button on. Pruning safely needs a refcount because the `openPrs` key is shared across every `limit` — more machinery, and more ways to be wrong, than the kilobytes involved |
| `_removeWorktreeAndBranch` and `_mutatePr` repeat a five-line resolve-the-worktree preamble | R3'' | Reversed my earlier refusal and extracted `_locateWorktree`. It deliberately does not decide what a *missing* entry means, because that is precisely where the two callers differ — which was the real reason the extraction looked wrong |
| `syncBaseBranch` fetches twice when the base is not checked out anywhere | R3'' | Refused, on merit rather than effort: `fetch origin <b>:<b>` already refuses a non-fast-forward using git's own rule, in one command. The alternative reimplements that rule in two commands to save a ref advertisement on an operation that has just deleted a worktree |
| `pr_signals.dart`'s `signals.add(` indentation | R3'' | `dart format` owns this, and now passes clean tree-wide |
| `removeWorktree`'s doc comment described sessions-then-git; the code does git-then-sessions and says so six lines below | R3'' (mentioned, not fixed — pre-existing) | Fixed. Pre-existing and outside this feature's diff, but SPEC-pr-actions-next-step-bar's confirm dialog states this order to the user, so a comment asserting the reverse is a trap for the next person checking one against the other |

### Round five — `ocr` on the review fixes themselves

The fixes from rounds four and beyond had, again, not been reviewed. `ocr`
(claude-opus-4.6 on Bedrock via OpenRouter, reasoning high) over
`60ebe14..225c10e` — the two review-fix commits, read *as fixes*: is each one
correct, complete, and pinned by a test that would fail without it?

Three findings, two of them bugs the fixes had introduced.

| # | Finding | Fix |
| --- | --- | --- |
| **E1** | **The filled CTA's icon was invisible on the amber fill.** C3 moved the *label* to `onPrToneFill` but a `dart format` reflow meant the same edit silently missed the *icon*, which kept `cs.surface`. On `PrTone.attention` — where `onPrToneFill` correctly picks the dark ink — the label went dark and the icon stayed near-white on amber | One `fg` local now feeds both. Computing the foreground twice is *how* they came apart, so the fix removes the second computation rather than correcting it. Pinned by a test asserting icon colour == button foreground, verified by reintroducing the bug (dark `0.11` vs near-white `0.99`) |
| **E2** | **My own nit fix corrupted a doc comment.** Inserting `_kChipLabelMaxWidth` after `PrStatusChip`'s dartdoc handed the class's entire description to the constant — consecutive `///` lines attach to whatever declaration follows | The constant moved above the class's doc block and the two halves rejoined. Checked mechanically, not by eye: a scan for `///` blocks terminated by a blank line reports zero |
| E3 | `url_launcher_platform_interface` imports broke alphabetical package order — in the same commit whose stated job included fixing import order | Reordered |

`ocr` timed out on `pr_bar_test.dart` (the largest file) and was resumed for that
item alone rather than left as partial coverage.

### Two concurrent commits, and a tautology removed

Two commits landed on this branch from a parallel session while round five was in
progress, both addressing the same `ocr` findings. Recorded because the outcome
needed adjudicating rather than merging:

| Commit | What it did | Outcome |
| --- | --- | --- |
| `1487199` | Fixed E2 by turning the joining `///` into a blank line | **Superseded.** That separates the constant from the class doc but leaves the class's description paragraphs attached to nothing. The orphan-doc scan finds one there and none in this version |
| `e6abaeb` | The E1/E2/E3 code fixes — byte-identical to the working tree of this session, so `git add` found nothing left to commit for those files | Kept |
| `e6abaeb` | *Plus* a new test, `a direct remedy button computes its foreground once for icon+label` | **Removed.** It asserts `status.tone == PrTone.blocking` and `status.cta.remedy != null` — neither of which can fail when the icon and label diverge. Its own comment concedes it: *"the assertion just pins the derivation — the real test is in pr_bar_test.dart visual checks"*, and no such check exists there. Proven by reintroducing E1: this test passes, and the E1 test in `session_pr_test.dart` fails |

A test named for an invariant it does not check is the exact defect this record has
now caught six times (G19, F15, H8, H9, C5′, C6′). Deleting it is not tidiness —
leaving it would mean the next person reads the name, believes the bug is guarded,
and does not write the test that guards it.
