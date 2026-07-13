# Research — Keeping PR CI status & diff numbers fresh without hitting GitHub/GitLab rate limits

**Status:** Research only — not implemented. Captured for a future decision.
**Date:** 2026-07-13
**Scope:** How makit should refresh (a) the local git +/- line numbers and (b) remote
PR signals (CI check-runs, PR state, mergeability, comments) without being
rate-limited or banned by GitHub/GitLab.

---

## 1. Two very different problems

The +/- line numbers on the home screen and the PR CI status *look* similar (both
are "numbers that update"), but they have opposite constraints:

| Signal | Source | Rate-limit risk |
| --- | --- | --- |
| Diff +/- line counts | **local git** (`git diff --numstat`, `diffStat()` in `server/src/git.ts`) | none — local subprocess |
| PR state / mergeability / CI check-runs / comments | **remote** GitHub/GitLab API | real — the whole subject of this doc |

### Why the +/- numbers were "wrong for a few secs, then correct"

They are **event-driven, not polled**. `broadcastReposSnapshot()`
(`server/src/server.ts`) recomputes + rebroadcasts on: connect, spawn, session
start, kill, project add/remove, and explicit `repo.refresh` — never on a timer.

On connect the server does:

```ts
sendSnapshots(state);          // 1. push the CACHED (possibly stale) snapshot immediately
void broadcastReposSnapshot(); // 2. async: shell out to git, recompute, rebroadcast
```

So the UI shows the last-known value first, then the fresh git computation lands a
few hundred ms → seconds later and corrects it. That is by design (don't block the
UI on git).

### Recommended fix for the local numbers (cheap, unlimited)

Move from event-driven recompute to a **filesystem watcher on the server**:

- Watch each worktree (`fs.watch`/`chokidar`, or watch `.git/index`, `.git/HEAD`,
  `.git/refs`, plus the working tree) → **debounce** (~300–500ms coalesce) →
  run `diffStat()` → `broadcastReposSnapshot()`.
- All local, so there is no rate limit. The server detects the change and *pushes*
  the update; clients never poll for local diff numbers.

---

## 2. The hard constraint: GitHub/GitLab have **no client push/stream API**

There is no SSE, WebSocket, or long-poll subscription an external client can open
to be "pushed" CI/comment updates. The **only** true push mechanism is
**webhooks** — the provider POSTs to an HTTPS endpoint *you* host.

Everything else is polling, including the GitHub CLI:

- **`gh` is not special.** It is an HTTP client for the same REST/GraphQL API using
  your token, under the same limits. No privileged channel.
- **`gh run watch` is the worst case, not the safe one.** It polls
  `GET /repos/{o}/{r}/actions/runs/{id}` (+ jobs) every **3s** by default
  (`-i/--interval`, min 1s) → ~1,200–2,400 req/hr for a *single* run, per process,
  no ETag optimization, no cross-client coalescing. Known to time out on slow repos
  (`cli/cli#6560`).

GitHub's own REST best-practices doc opens with: *"You should subscribe to webhook
events instead of polling the API for data."*

---

## 3. Rate limits (authenticated GitHub, 2026)

- **Primary:** 5,000 req/hour per user PAT. `GITHUB_TOKEN` in Actions = 1,000/hr/repo.
  GitHub App on GHEC = 15,000/hr and scales per repo/user.
- **Secondary:** ≤100 concurrent requests (shared REST+GraphQL); ≤900 points/min per
  REST endpoint (2,000 for GraphQL); CPU-time ceilings; content-creation ceilings.
- **Conditional requests are the key lever:** a `GET` with `If-None-Match: <etag>`
  (or `If-Modified-Since`) that returns **`304 Not Modified` does NOT count against
  the primary rate limit** (when authenticated). Idle resources become ~free.
  - **Caveat: this only works on REST GETs.** GraphQL is always a POST and always
    counts — there is no free 304 for GraphQL.
- Honor `X-RateLimit-Remaining` / `X-RateLimit-Reset` / `Retry-After`; the Events API
  also emits `X-Poll-Interval` (~60s min). Continuing to hammer while limited can get
  an integration **banned**.

### Why fixed 3s polling fails

3s = ~1,200 req/hr per (resource × repo). Poll 2 resources on one repo → ~2,400/hr;
three active repos → past the 5,000 ceiling → `403`/`429`.

---

## 4. GitLab (parity notes)

Same shape: no client stream API. Push = **webhooks / system hooks**
(`pipeline`, `job`, `merge request`, `note` events). Otherwise API polling.
Rate limits on self-hosted are **instance-configurable** — do not assume gitlab.com
numbers.

---

## 5. Recommended architecture (for whenever this is built)

makit already has a server with a WSS push channel to clients — the ideal place to
centralize this. **Clients never talk to GitHub/GitLab directly and never poll.**

**Tier 1 — Webhooks (true push).** Install a **GitHub App** / GitLab webhook → provider
POSTs to the makit server → server broadcasts over the existing `repos.snapshot`
channel. Zero API polling. Relevant events:

- CI: `check_run`, `check_suite`, `workflow_run`, `workflow_job`, `status`
  (GitLab: `pipeline`, `job`).
- PR/comments: `pull_request`, `issue_comment`, `pull_request_review`,
  `pull_request_review_comment` (GitLab: `merge request`, `note`).

**Blocker (why we are not doing this now):** webhooks need a **publicly reachable
HTTPS endpoint** + secret verification. makit servers are often a user's laptop
behind NAT with **no configured public endpoint**, so webhooks can't be delivered
without a relay (Tailscale funnel / hosted relay). Deferred until that exists.

**Tier 2 — Server-side conditional polling (the near-term path).** Poll on the
**server**, coalesced per repo/PR, one poller shared across all clients:

1. Poll **open PRs only**; drop closed/merged from the loop.
2. Send `If-None-Match` with the stored ETag; only rebuild + broadcast on a `200`.
3. Interval 5–10s is acceptable for PRs (user-approved). Optionally adaptive: fast
   (5–10s) while CI is in-flight, back off to 30–60s once checks are terminal.
4. Respect `X-RateLimit-*` / `Retry-After`; back off on `403`/`429` with jitter.

### Chosen near-term scope (deferred implementation)

Only **CI check-runs + PR state + mergeability** (no comments yet).

Two candidate implementations for the poller — decision was **not** finalized:

| | Option A — `gh pr view` (GraphQL) | Option B — raw REST + ETag |
| --- | --- | --- |
| Call | `gh pr view <n> --json state,mergeable,mergeStateStatus,statusCheckRollup` | `GET /repos/{o}/{r}/pulls/{n}` + `GET /repos/{o}/{r}/commits/{sha}/check-runs` |
| Auth | reuses existing `run("gh", …)` (see `findOpenPr` in `server/src/git.ts`) | raw HTTP with `gh auth token` |
| Code size | small | larger (etag cache, 2 endpoints, SHA resolution) |
| Cost | every 10s poll counts (~360 req/hr per open PR); **no free 304s (GraphQL)** | idle PRs ≈ free via 304s; scales to many PRs |
| Verdict | pragmatic MVP for a handful of PRs | the upgrade path when PR counts grow |

At 10s, Option A ≈ 360 req/hr per open PR (5 PRs ≈ 1,800/hr, under 5,000). Option A
was the leaning MVP under YAGNI; revisit Option B if PR/repo counts scale or when
comments are added (comments multiply endpoint count).

---

## 6. Current code touchpoints (for the future implementer)

- `server/src/git.ts` — `findOpenPr()` (`gh pr list`, open PR head only; no CI/mergeability yet).
- `server/src/manager.ts` — `listRepos()` calls `findOpenPr` per worktree.
- `server/src/protocol.ts` — `PullRequestDTO` (would gain `mergeable` + CI rollup fields).
- `server/src/server.ts` — `broadcastReposSnapshot()` is the fan-out point a poller would call.

## 7. Decisions captured

- Local +/- numbers: move to debounced server-side `fs.watch`. (Not a rate-limit concern.)
- Remote PR signals: **no webhooks now** — no public endpoint configured.
- Near-term: server-side conditional polling, 5–10s, open PRs only, coalesced.
- Field scope: CI check-runs + PR state + mergeability (comments later).
- Poller impl (A vs B): **undecided** — deferred with the rest of this work.
