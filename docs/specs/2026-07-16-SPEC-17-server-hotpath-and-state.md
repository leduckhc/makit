# SPEC-17 — Server hot-path performance & session state model

**Status:** Proposed · **Priority:** P1 · **Source:** `docs/research/2026-07-16-code-quality-audit.md` §2 P2–P4
**Scope:** `server/src/server.ts`, `server/src/manager.ts`, `server/src/session.ts`, `server/src/git.ts`.

---

## 🚦 Branch & worktree gate (NO GO if not met)

This spec **MUST** be implemented in a **new git worktree branched from `chore/code-quality-review`**, and its **pull request MUST target `chore/code-quality-review`** (not `main`).

- Base branch: `chore/code-quality-review`
- PR target branch: `chore/code-quality-review`

If either condition is not satisfied, **this spec is NO GO**.

```bash
git fetch origin chore/code-quality-review
git worktree add ../spec-17-server-perf -b spec-17/server-hotpath origin/chore/code-quality-review
```

---

## Goal

Remove the two real scaling cliffs on the hot paths (streaming + home screen) and
replace the convention-enforced draft state with a compiler-enforced model.

## Work items

### P2 — Stop broadcasting the full sessions snapshot per streaming delta

- **Where:** `server.ts:576-585` (`wireSession`).
- **Problem:** `session.on("event", ...)` calls `broadcastSessionsSnapshot()` —
  which serializes **every** session DTO to **every** client — once per
  `agent.message.delta` token. O(clients × sessions) per token. The session list
  only changes on title/status/preview transitions.
- **Fix:** re-broadcast the sessions snapshot only when a session's DTO-visible
  fields change. Preferred: have `Session` emit a distinct `metaChanged` event
  (title/status/preview) separate from `event`, and wire the snapshot fan-out to
  `metaChanged` only. (Debounce/coalesce is an acceptable fallback.)

### P3 — Parallelize `listRepos`

- **Where:** `manager.ts:392-448`; compounded by `git.ts:150-156`
  (`listWorktrees` per-worktree `git log -1`).
- **Problem:** per project, serial `isGitRepo → detectDefaultBranch →
  detectCurrentBranch → listWorktrees`, then a serial loop of `diffStat` +
  `gh findOpenPr` (5s timeout) per worktree. N projects × M worktrees sequential
  process spawns on the home path.
- **Fix:** `Promise.all` over projects; within a project `Promise.all` over
  worktrees for `diffStat`/`findOpenPr`; parallelize the per-worktree `git log -1`
  in `listWorktrees`. These are independent read-only shells. Bound concurrency
  if needed. Extracting a `RepoService.listRepos()` (see SPEC-19 D-manager) makes
  this localized and testable — coordinate if both land.

### P4 — Model the pending-draft lifecycle as a discriminated union

- **Where:** `session.ts:60-77` (`pending`, `pendingAgent`, `pendingBaseBranch`,
  `pendingWorktreePath`, `branch`, `worktreePath`), mutated across `manager.ts`.
- **Problem:** the draft→started state machine is smeared across 6 mutable
  optional fields; invariants ("pendingWorktreePath only meaningful while
  pending"; "branch set at start") are enforced by convention.
- **Fix:** `type SessionLifecycle = { phase:"draft"; agent; baseBranch?; worktreePath? } | { phase:"started"; branch; worktreePath }`.
  `markStarted` becomes a transition; `toDTO` becomes a `switch`; the manager can
  no longer read `pendingWorktreePath` on a started session.

## Verification (definition of done)

- New server test: a stream of N deltas triggers **≤1** sessions-snapshot
  broadcast (asserts P2 — no per-token fan-out); a title/status change **does**
  broadcast.
- New/updated test asserting `listRepos` issues its per-worktree shells
  concurrently (e.g. via an injectable clock/spy), and results are unchanged.
- Type-level: reading `pendingWorktreePath` on a `started` session is a compile
  error. Existing manager/session tests pass.
- `cd server && pnpm typecheck && pnpm test` green.

## Non-goals

- No change to the WS wire protocol or DTO shape (P2 changes *when* snapshots are
  sent, not their content). No new git/gh capabilities.
