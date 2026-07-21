# SPEC-23 — Live PR status + PR action pills (desktop)

**Status:** In progress · **Depends on:** SPEC-10 (desktop chat), SPEC-11
(repo-centric home, `PullRequestDTO`), the PR research note
([`docs/research/2026-07-13-github-gitlab-live-updates.md`](../research/2026-07-13-github-gitlab-live-updates.md)) ·
**Scope this sprint:** macOS desktop only. Mobile parity is an explicit
fast-follow (the protocol/model changes are shared, so mobile inherits the data
for free; only the desktop widgets ship now).

## Goal

Materialize the SPEC-10 Phase-5 "PR workflows" roadmap and fix the concrete bug
that **PR status never updates in the UI on its own**. Four outcomes:

1. **Auto-update PR status.** The server keeps open-PR status (state, CI checks,
   mergeability) fresh and pushes changes to clients without a manual refresh.
2. **Permanent PR pill above the composer** that opens the PR on the web.
3. **CI-run state on hover** of that pill (per-check pass/fail/pending list).
4. **A split "PR actions" button** whose items (Create PR, Fix PR, Resolve
   comments) are pre-configured prompts the user can override in Settings.

## Why the status was stale (root cause)

`broadcastReposSnapshot()` (`server/src/server.ts`) is **event-driven only** —
it fires on connect, spawn, session start/kill, project add/remove, explicit
`repo.refresh`, and the `fs.watch` worktree watcher. None of these fire when a
*remote* signal changes (CI finishes, a review lands, the PR is merged). GitHub
has **no client push/stream API** (research §2), so the only near-term option is
**server-side polling** — decided in the research note and implemented here.

## Decision 1 — server-side adaptive poller (Tier 2 from the research)

- Poll **open PRs only**, coalesced: one poller shared across all clients.
- Data via the existing `gh` path — extend `findOpenPr` to request
  `--json number,url,state,title,isDraft,mergeable,mergeStateStatus,statusCheckRollup`
  in the **same** `gh pr list --head <branch>` call (verified: one call returns
  all of it — no second `gh pr view`).
- **Adaptive interval:** poll every ~10s while any tracked PR has in-flight
  checks; back off to ~60s once every tracked PR's checks are terminal. Back off
  further (with jitter) on `gh` failure. `unref()` the timer so it never keeps
  the process alive.
- The poller re-runs `broadcastReposSnapshot()` only when a tracked PR's
  status **actually changed** (structural compare of the normalized status),
  so idle PRs cost one cheap `gh` call and zero client traffic.
- Webhooks (true push) remain deferred — no public endpoint on a laptop server
  (research §5, Tier 1).

## Decision 2 — normalized check model

`statusCheckRollup` mixes `CheckRun` (Actions) and `StatusContext` (legacy
commit-status) shapes. The server normalizes both into a compact list plus a
single rollup so the app has no provider-shape logic:

```ts
type PrCheckBucket = "pass" | "fail" | "pending" | "skipping" | "cancel";
interface PrCheckDTO { name; bucket; workflowName; detailsUrl }
// PullRequestDTO gains: mergeable, mergeStateStatus, checks[], checkRollup
type PrCheckRollup = "pass" | "fail" | "pending" | "none";
```

Rollup: any `fail`/`cancel` → `fail`; else any `pending` → `pending`; else any
`pass` → `pass`; else `none` (empty / all skipped).

## Decision 3 — PR actions are client-owned canned prompts

The split button's items are **app-level canned prompts**, agent-agnostic (they
do not depend on a harness exposing a matching slash-command). Selecting one
**inserts its text into the composer** (it does **not** auto-send) — sending a
prompt to an agent is consequential, so the user reviews + hits Send, matching
the existing slash-palette "insert, don't send" behavior. Fixed action set this
sprint (Create PR / Fix PR / Resolve comments); each action's prompt text is
overridable via a desktop `PreferenceEntry` (empty override = built-in default).

## Surface (desktop chat pane)

A single row sits directly above the docked `Composer`, capped to the same
readable width:

```
[ PR #42  ✓ ]                                   [ ⌄ | PR actions ]
  └ opens PR on web; hover → per-check list        └ caret = menu; main = last-picked action
```

- The **PR pill** renders only when the pane's worktree has an open PR (mirrors
  the existing `PrPill` gate). Tint follows `checkRollup` (green pass / red fail
  / amber pending / neutral none) with the draft-grey override.
- The **actions split button** always shows (its actions include "Create PR",
  the path to *getting* a PR), mirroring the `open_in_ide.dart` split-button
  M3 pattern.

## Out of scope (this sprint)

- Mobile widgets (fast-follow; data already flows to mobile).
- GitLab (`glab`) — GitHub only, matching current `gh`-only code.
- PR comments ingestion; "Resolve comments" just sends a prompt telling the
  agent to fetch + address review comments via its own tools.
- Webhooks / REST+ETag poller (research Tier 1 / Option B) — revisit if PR
  counts scale.

## Acceptance criteria

- [ ] With an open PR, finishing CI (or merging) updates the pill within one
      poll interval with **no** manual refresh.
- [ ] The pill opens the PR URL on the web; hover lists each check + state.
- [ ] The split button inserts the (possibly overridden) prompt into the
      composer; Settings edits the three prompts and resets to default.
- [ ] `cd server && pnpm test && pnpm typecheck` green; `cd app && flutter test
      && flutter analyze --fatal-infos` green; `app/tool/audit.sh` passes.
