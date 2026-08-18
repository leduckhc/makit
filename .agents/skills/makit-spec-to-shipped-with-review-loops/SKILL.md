---
name: "makit-spec-to-shipped-with-review-loops"
description: "Ship a makit feature through spec → dual codex spec review → parallel server/app implementation → three-reviewer code round → controller-verified fixes"
---
## When to Use
Use when shipping a whole makit feature end-to-end (server + Flutter app) under this repo's strict TDD/SOLID/YAGNI rules, where the user wants written spec + plan, review loops before and after implementation, and evidence rather than claims. Also use for the narrower case of adding a host-wide (non-session) broadcast event or a watch-gated background scan.

## Procedure
1. Find the precedent feature before writing anything. Grep for the closest existing subsystem (for a watch-gated host-wide broadcast that is SPEC-performance-metrics-dashboard metrics: `metrics.watch`, `HOST_ONLY_KINDS`, `metrics/proc_table.ts`, `MetricsWatch`) and name it in the spec's 'what P1 reuses' table. Half the design work is already committed.
2. Write the spec with a locked `## Decisions (D1..Dn)` table and an explicit `## What P1 does not do`. Phase the feature (P1..P4) so deferred surfaces do not have to be redesigned later.
3. Write the plan as tasks that each state a RED TEST and a VERIFY command, ordered so the contract fixture is red first and any vocabulary/shared module precedes its consumers.
4. Review the spec+plan with TWO parallel codex jobs in `.piano/codex-jobs/<stamp>-<slug>/` (prompt.md, run.sh, codex.log, pid). A review job reads and reports, so run it `--sandbox read-only`: with `workspace-write` two parallel jobs edit the same checkout and clobber each other's findings. If a job must write (a scratch probe), give it its own worktree and its own `CODEX_HOME`. Run one job for technical correctness (make it RUN the shell commands the plan depends on and check them against the real binaries), one for SE practice (TDD/SOLID/YAGNI/house-style, with an explicit 'CUT THIS' and 'MISSING' list).
5. Triage those findings yourself against the code, then rewrite the spec+plan as rev 2 with a `## Review findings applied` section that also records what you REJECTED and why.
6. Do the shared wire contract yourself (protocol + fixture + guard test) and commit it, so parallel agents cannot both edit it.
7. Prepare toolchains (`pnpm install` in server/, `flutter pub get` in app/), then dispatch ONE agent per disjoint tree (server/ vs app/) in the background, each with: the read order, the frozen contract, an explicit path allow-list and deny-list, per-task red tests, the known project traps, and 'STOP and report if the spec is unbuildable'.
8. Verify the agents' claims yourself: run tsc + both suites, `git diff --stat` for overreach, and read the highest-risk diffs. Never accept a reported pass count without re-running it.
9. Commit, then run THREE reviews on the diff in parallel: codex for code correctness (told to run the real commands and to name any vacuous test), codex for spec/plan adherence (told to check each locked decision and to propose mutations proving each test bites), and `ocr review --audience agent --from <ref> --to HEAD -b '<context>'` for line-level code comments.
10. Triage every finding by reading the code yourself; confirm the serious ones before dispatching fixes. Then dispatch one fix agent per tree with the verified findings, each requiring a red test first and a stated mutation that proves it bites.
11. Run the review loop a SECOND time, scoped to 'check the fixes, not the feature', asking for a FIXED/PARTIAL/NOT FIXED/REGRESSED verdict per finding. Fix the remainder yourself if small.
12. Do the live proof the tests cannot give: a throwaway probe that runs the real code against the real machine, compared against ground truth by eye. Delete the probe; record what it revealed in the spec's Verification section — including limitations it exposes.
13. Fill the plan's Deviations log with every departure (including ones reverted on review) and flip the spec Status to Implemented with a results table.

## Pitfalls
- A fresh linked worktree has no `server/node_modules` and no `app/.dart_tool` — run `pnpm install` in server/ and `flutter pub get` in app/ BEFORE dispatching agents.
- `server/src/git.ts`'s `run()` NEVER rejects: spawn faults and timeouts resolve as `{code:127, stdout:''}`. Check `code` explicitly or a missing binary reads as a successful empty result.
- **A watch-gated index keyed off the repos snapshot will be EMPTY on first use.** The app sends `<x>.watch {on:true}` from a screen's initState, which lands right after `hello.ack` and BEFORE the server's first `repos.snapshot`. The 0→1 edge scans synchronously, sees no worktrees, and broadcasts an empty index; the filesystem watcher never fires because nothing changed, so it never recovers. Call `<svc>.onWorktreeChange()` where `lastGitOnlyRepos = gitOnly` is assigned in server.ts. Unit tests cannot see this — they all supply the worktree list up front.
- **A dedicated HTTP listener needs a terminal 404 handler.** A route attached with `server.on('request')` that early-returns for paths it does not own leaves the socket unanswered until Node's 60s headers timeout when nothing else is attached. Safari requests `/favicon.ico` on every visit, so on a routable listener that is a free socket-exhaustion vector. Attach a `notFound` listener LAST, only on dedicated listeners.
- Adding a host-wide broadcast kind needs THREE places: the `SessionEventKind` `Exclude<>`, `HOST_ONLY_KIND_FLAGS`, and the `EVENT_KINDS` runtime set. Type the runtime lists as `Record<EventKind, true>` / `Record<Exclude<EventKind, SessionEventKind>, true>` so drift is a build error.
- `EVENT_KINDS` membership of a HOST-ONLY kind is unobservable at runtime: `decodeFrame` validates only `v`/`t`/`id` and never inspects `kind`, and `decodeSessionEvent` rejects host-only kinds before consulting it. Any test asserting it is vacuous.
- Do NOT add a host-wide event fixture to `server/test/fixtures/events.json` — it asserts one entry per *session* kind. Use `snapshots.json`.
- A security test can be vacuous through over-defence: a 'prefix confusion' test using `../` never reaches the containment check because the segment rule rejects `..` first. Reach it through a SYMLINK into a sibling dir sharing the prefix (`<root>-evil`).
- **A glyph that hides when empty, plus a watch held only by the destination screen, is an unreachable feature.** The mobile entry to a screen was its own worktree-row glyph, but only that screen held the watch — so no snapshot arrived, the glyph never rendered, and the screen could not be opened at all. Hold the watch on the row (as `worktree_row.dart` already does for `ports.watch`). Widget tests miss it because they inject the provider directly.
- In Dart a `Map` literal is never `==` to another Map, so `expect(list, contains({...}))` can NEVER match. Record scalars (e.g. the bool) or use `equals([...])` deep matching.
- Riverpod asserts on changing the NUMBER of overrides between `pumpWidget` calls ('overrides cannot be removed/added'). Build the ProviderScope once via a helper and swap only its child when testing dispose behaviour.
- `test/e2e-server.ts` replies to `hello` with `t: "hello.ack"` — not `hello.ok` and not a bare `ack`. A probe keyed to the wrong type silently never sends its next command and looks like a server hang.
- Run only ONE `flutter test` at a time: two concurrent runs collide over `.dart_tool` and the second dies with `Test directory "test" not found`, silently measuring nothing.
- app/ flake baseline moved with Flutter 3.44.9: 26–37 files fail at the `loading <file> [E]` stage per full run (was ~8), still random, still present at `--concurrency 1`, and every file passes alone. This excuses ONLY `loading`-stage errors. Still run the full suite before you hand off. Treat every non-`loading` failure, and every file that fails in ALL runs, as a real failure to fix — an isolated green file does not prove the suite is free of cross-test contamination. Record each accepted flake by name.
- `request()` in the app installs a 10s ack-timeout timer; calling it from initState leaks timers and fails dozens of unrelated tests. Use fire-and-forget `send` for watch toggles.
- Verifying a fix by `git stash` removes the new test AND the fix. Revert only the production line.
- `dart format .` walks `build/`, where cargokit writes generated unformatted Dart. Scope to `lib test integration_test`.
- Running `node --import tsx` (or a probe importing `ws`) from the repo root fails with ERR_MODULE_NOT_FOUND — both live in `server/`. cd there first.
- A live probe over the REAL corpus beats more unit tests for extraction logic: title extraction across 131 real docs found an H2-only case worth handling and disproved a suspected SKILL.md front-matter gap, turning a speculative feature into a YAGNI deletion.
- Pre-existing and still unfixed: `desktop/chat/desktop_sidebar.dart` calls `context.go('$kRoutePorts?repo=…')`, but the desktop shell is a plain `MaterialApp(home:)` with no GoRouter — it throws at runtime while tests pass (they wrap in a GoRouter).
## Verification
1. `cd server && node_modules/.bin/tsc -p . --noEmit` clean and `npm test` all-green, with the pre-existing count preserved (e.g. 918 → 1007, none failing).
2. `cd app && flutter analyze --fatal-infos --no-pub` reports 'No issues found' and `flutter test --no-pub` is all-green with the baseline preserved.
3. Every new test's bite is proven by reverting only the production line and watching that test fail.
4. A real-machine acceptance test (real lsof/ps, real listener, real worktree) passes, plus a manual live comparison against ground truth.
5. `git status --short` is empty and the mockups, spec Status, results table and Deviations log all match what actually shipped.
