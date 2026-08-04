# SPEC-32 — Centralised GitHub gateway + API budget indicator

**Status:** proposed · **Date:** 2026-07-31 · **Depends on:** SPEC-23 (PR status & actions), SPEC-19 (decomposition), SPEC-11 (repo-centric home)

---

## 1 · Problem

We hit GitHub's rate limit constantly, and when we do, **PR pills render wrongly or
vanish from the UI**.

Today every GitHub read is an independent `gh` subprocess, spawned from five call
sites with no shared knowledge of cost, cache, or remaining quota:

| Call site | Command | Frequency |
|---|---|---|
| `git.ts:fetchOpenPr` | `gh pr list --head <branch> --json …statusCheckRollup` | per tracked branch, **every 5s** (`server.ts` sets `fastMs=slowMs=5_000`) |
| `git.ts:unresolvedReviewThreadCount` | `gh api graphql` reviewThreads, **paged up to 100×** | on **every** `fetchOpenPr` |
| `git.ts:listOpenPrs` | `gh pr list` | per PR-picker open |
| `git.ts:addWorktreeForPr` | `gh pr checkout` | user action |
| `repo_service.ts:enrichPrs` | `findOpenPr` fan-out, `PR_CONCURRENCY=6` | per connect / spawn / refresh |

With *N* tracked branches the poller alone issues **≥2N calls every 5 seconds** —
1,440·N calls/hour against a 5,000/hour quota. Ten branches exhausts the quota in
under 21 minutes, and that is before the terminal, Codex, or any other agent on the
same token spends a single request.

Three distinct defects follow:

1. **No shared budget awareness.** Nothing reads `X-RateLimit-*`; nothing knows how
   much is left; nothing backs off. The first symptom of exhaustion is broken UI.
2. **A throttled lookup is indistinguishable from a deleted PR — in `enrichPrs`.**
   Traced precisely (2026-07-31):
   - `pr_watcher` is **innocent**. It calls `fetchOpenPr`, which *throws* on a
     transient failure, and its poll loop already retains the last-known signature
     (`if (!ok) continue;`). Its three-way contract works today.
   - `repo_service.enrichPrs` is the culprit. It calls **`findOpenPr`** — the lenient
     wrapper that collapses *both* "no open PR" and "lookup failed" into `null` — and
     assigns that straight onto the DTO (`out[t.ri].worktrees[t.wi].pr = prs[i]`).
   - `server.ts:broadcastReposSnapshot` then calls `emit(repos)` for the enriched
     phase **without** `preserveLastKnownPrs`, which is applied only to the git-only
     phase.

   So a single 403 during enrich erases every affected pill until some later snapshot
   happens to succeed. **This is the missing-pill bug**, and the fix belongs in
   `enrichPrs` + the enriched broadcast — not in the watcher.
3. **No cache and no coalescing.** `enrichPrs` and `pr_watcher` ask the same
   question seconds apart and both pay.

## 2 · Goals

- **G1** One module owns every GitHub read. No call site spawns `gh` for data.
- **G2** A throttled or failed lookup **never** removes a PR from the UI. Last-known
  state is retained and marked stale.
- **G3** Quota is measured, attributed (makit vs. other tools on the same token), and
  surfaced in the sidebar footer.
- **G4** As quota drains, the gateway degrades on a fixed ladder rather than failing.
  User-initiated actions are never starved.
- **G5** REST and GraphQL are treated as two independent budgets, and each request is
  routed to whichever bucket can better afford it.

## 3 · Non-goals

- **Direct HTTP to `api.github.com`.** Decided against (2026-07-31): the gateway
  shells out to `gh`, keeping auth, enterprise hosts, and token refresh as the CLI's
  problem. Consequence: **no ETag / conditional requests**, so we cannot make
  revalidation free. Cache TTL + call elimination must carry the whole saving.
- **Webhooks.** No public HTTPS endpoint on a laptop (SPEC-23 research §5).
- **Multi-account / GH Enterprise.** Single `gh` login, single host.
- **Mobile UI for the budget.** Desktop sidebar footer only.

## 4 · Quota model (the facts the design rests on)

GitHub exposes **separate, independent** buckets. `gh api rate_limit` reports all of
them, and **`GET /rate_limit` is itself exempt** — polling it costs nothing.

| Bucket | Limit | Window | Used by |
|---|---|---|---|
| `core` | 5,000 | hour (fixed reset) | REST endpoints, `gh pr checkout` |
| `graphql` | 5,000 **points** | hour (fixed reset) | `gh api graphql`, **and `gh pr list --json`** |
| `search` | 30 | **minute** | nothing in makit — see §7.3 |

Two consequences that shape everything below:

- **`gh pr list --json` is GraphQL, not REST.** Our hot path spends the *graphql*
  bucket, so "REST remaining" was never the number to watch.
- **GraphQL is the cheap path.** Its limit is *points*, and a single-PR query costs
  ~1 point while returning identity + mergeability + check rollup + review threads.
  The REST equivalent is 3–4 calls:

| Field | GraphQL | REST |
|---|---|---|
| identity, draft | part of 1 query | `GET /repos/{o}/{r}/pulls?head=…` |
| `mergeable` | same query | `GET /repos/{o}/{r}/pulls/{n}` (computed async) |
| check rollup | same query | `GET …/commits/{sha}/check-runs` **+** `…/status` |
| unresolved review threads | same query | **no REST equivalent** — REST review comments carry no `resolved` field |

So REST is a *fallback*, not a peer: it costs ~4× and cannot supply
`unresolvedComments` at all.

## 5 · Architecture

```
                    ┌───────────────────────────────────────────┐
  repo_service ────▶│              GithubGateway                │
  pr_watcher   ────▶│  cache · dedupe · concurrency · spend log  │──▶ gh (subprocess)
  worktree cmds ───▶│                                           │
                    └───────┬───────────────────┬───────────────┘
                            │                   │
                    ┌───────▼──────┐    ┌───────▼────────┐
                    │ BudgetTracker│    │ RequestRouter  │
                    │ (§6.1)       │    │ (§6.2)         │
                    └───────┬──────┘    └────────────────┘
                            │ budget snapshot
                            ▼
              server.ts ──▶ `github.budget` event ──▶ app store ──▶ footer popover
```

New files, all under `server/src/github/`:

| File | Responsibility | Purity |
|---|---|---|
| `budget.ts` | Parse `rate_limit`; track spend, burn rate, attribution, status level | pure + clock injected |
| `policy.ts` | Degradation ladder: poll interval, shed decisions, reserve floor | pure |
| `router.ts` | Cost-aware REST/GraphQL path choice with hysteresis | pure |
| `gateway.ts` | The single door: cache, dedupe, concurrency, `gh` exec, spend recording | side-effecting, DI'd |
| `queries.ts` | The `gh` argv for each request kind (GraphQL primary, REST fallback) | pure |

`git.ts` keeps its exported functions (`fetchOpenPr`, `listOpenPrs`, …) as the public
API — they gain a `GithubGateway` parameter instead of calling `run("gh", …)`. This
keeps the blast radius small: `repo_service`, `pr_watcher`, and the worktree commands
keep their current imports.

## 6 · Component design

### 6.1 BudgetTracker (`budget.ts`)

```ts
export type BucketName = "core" | "graphql" | "search";

export interface BucketState {
  limit: number;
  remaining: number;
  /** Epoch ms when the window resets (GitHub's reset is absolute, not rolling). */
  resetAt: number;
  /** Requests we attribute to makit in this window. */
  mine: number;
  /** limit - remaining - mine; spend by other tools on the same token. */
  others: number;
}

export interface BudgetSnapshot {
  buckets: Record<BucketName, BucketState | null>;
  /** Observed requests/hour over the trailing window (default 10 min). */
  burnPerHour: number;
  /** Ms until the governing bucket empties at `burnPerHour`, or null if never. */
  msUntilEmpty: number | null;
  level: "healthy" | "warm" | "critical" | "paused" | "unknown";
  /** Active throttles, in ladder order — drives the popover's banner + badge. */
  throttles: string[];
  /** Set while a secondary (burst) limit is in force. */
  retryAfterMs: number | null;
  measuredAt: number;
}
```

- `mine` is counted by the gateway; `others` is **derived**: the shortfall between
  what GitHub says was consumed and what we know we consumed. This is the number that
  explains most real exhaustion events and is invisible today.
- `level` is driven by **`msUntilEmpty`**, not percentage remaining: `warm` <30 min,
  `critical` <5 min, `paused` at 0 remaining or on manual pause.
- Burn rate uses a trailing ring buffer of per-minute counts (60 slots), so the
  sparkline and the rate share one source.

### 6.2 RequestRouter (`router.ts`)

Each request kind declares its cost in both buckets:

```ts
interface PathCost { bucket: BucketName; units: number }
interface RequestPlan { primary: PathCost; fallback?: PathCost; degraded?: "omit" }
```

Routing rule — **spend from whichever bucket can better afford it**, measured as the
fraction of its own remaining headroom the call would consume:

```
score(path) = path.units / max(1, remaining(path.bucket))
choose argmin score
```

With graphql=4,188 and core=1,769: graphql scores 1/4188, REST scores 4/1769 —
graphql wins by ~9×. Once graphql falls below ~450 the arithmetic flips to REST on
its own. **No hand-tuned thresholds.** Three refinements:

1. **Hysteresis.** Once switched, stay switched until the loser is ≥20% better.
   Prevents per-tick flapping.
2. **Reset-imminence.** If the primary bucket resets within `min(2 min, cost of
   fallback in time)`, prefer to wait over paying 4× — the fixed reset returns the
   whole allowance at once.
3. **Never fail over on a secondary limit.** Secondary (burst) limits are per-token
   and apply to *both* buckets; switching path cannot help. The only correct response
   is lower concurrency + `Retry-After`. Failing over here would make it worse.

`unresolvedComments` has `degraded: "omit"` and **no fallback** — GraphQL-only. When
graphql is starved the field is dropped, and the DTO says so (§6.5).

### 6.3 Degradation ladder (`policy.ts`)

Pure function `decide(snapshot) → Policy`:

```ts
interface Policy {
  pollIntervalMs: number;      // 5s → 30s → 120s → Infinity (paused)
  includeUnresolved: boolean;  // first thing shed: most expensive, least essential
  concurrency: number;         // 6 → 2 under a secondary limit
  reserve: number;             // requests withheld from background work
}
```

| Trigger | Action |
|---|---|
| `warm` (<30 min headroom) | `includeUnresolved=false`, poll → 30s |
| `remaining < 900` | poll → 120s |
| `remaining < reserve` (300) | poll → paused; reserve held |
| secondary limit | `concurrency=2`, honour `Retry-After`; **no** bucket failover |
| manual pause | poll → paused |

**Interactive requests bypass the ladder entirely** and may draw on the reserve. A
user clicking "create PR" must never fail because a background poller was greedy.

### 6.4 Gateway (`gateway.ts`)

```ts
export interface GithubGateway {
  prForBranch(repoPath: string, branch: string, opts?: { interactive?: boolean }):
    Promise<PrLookup>;
  openPrs(repoPath: string, limit: number): Promise<OpenPr[]>;
  budget(): BudgetSnapshot;
  refresh(): Promise<BudgetSnapshot>;   // reads exempt /rate_limit
  setPaused(paused: boolean): void;
  onBudgetChange(fn: (s: BudgetSnapshot) => void): () => void;
  close(): void;
}
```

- **Cache**: keyed by request kind + args. PR lookups 20s TTL; `unresolvedComments`
  5 min; `openPrs` 60s. An `interactive` call bypasses the TTL.
- **Dedupe**: one in-flight promise per key — `enrichPrs` and `pr_watcher` asking
  concurrently costs one subprocess.
- **Spend accounting**: every `gh` invocation increments the bucket its plan names,
  *before* the call, so a burst cannot outrun the accounting.
- **Budget refresh**: `gh api rate_limit` on start, then every 60s and after any 403.
  Free, so no need to be clever.

### 6.5 `PrLookup` — the three-way result (fixes G2)

The whole missing-pill bug is a missing third state. Replace `PullRequestInfo | null`
with an explicit union:

```ts
export type PrLookup =
  | { kind: "pr"; pr: PullRequestInfo }     // definitely open
  | { kind: "none" }                        // definitely no open PR
  | { kind: "unknown"; reason: "throttled" | "error" };  // could not tell
```

- `pr_watcher` keeps its existing retain-on-failure behaviour: `unknown` takes the
  same path its `catch` takes today (no broadcast, keep the signature). Its contract
  is preserved, not rewritten. Only `none` clears a pill.
- `repo_service.enrichPrs` — **the actual bug site** — stops using `findOpenPr`. On
  `unknown` it retains the previously broadcast PR (via a `lastKnown` lookup passed in
  by the caller, which already owns `lastEnrichedRepos`) and sets `pr.stale = true`,
  instead of writing `null` onto the DTO.
- `PullRequestDTO` gains two optional fields (additive, back-compatible):

```ts
  /** True when this PR was not re-fetched successfully; shown dimmed. */
  stale?: boolean;
  /** True when unresolvedComments was shed to save quota (value not reliable). */
  unresolvedUnknown?: boolean;
```

### 6.6 Protocol (`github.budget`)

New `EventKind: "github.budget"`, payload = `BudgetSnapshot` plus a 60-slot
`history` array (per-minute `{mine, others}`) for the sparkline. Broadcast on
budget-level change or throttle change — **not** on every tick (it changes every
minute; the UI is idle most of the time).

Three commands: `github.refresh` (hits the exempt endpoint), `github.pause`
`{paused: boolean}`, and `github.watch` `{watching: boolean}`.

`github.watch` exists because the change-gated broadcast above, right for an idle
footer, is wrong for an *open* panel: `remaining`, `mine`, `others` and the burn
rate move continuously without crossing a level boundary, so a panel left open
sat on the numbers it opened with. While at least one client is watching, the
server re-reads `/rate_limit` every `WATCH_INTERVAL_MS` (10s) and pushes each
snapshot unconditionally **to the watchers only** (a paired phone has no budget
panel, so it is not sent six snapshots a minute); the first read happens
immediately on subscribe, and a read still in flight suppresses the next tick
rather than stacking `gh` subprocesses. The
cadence is scoped to an open panel rather than made global because the reads,
though quota-**exempt**, each cost a `gh` subprocess through the gateway's
concurrency gate. Watchers are per-client and dropped on disconnect, so a client
that vanishes with the panel open cannot pin the fast loop on. The client
re-issues `github.watch` on reconnect, exactly as it replays `sub`.

## 7 · UI (desktop sidebar footer)

Mockup: **`mockups/github-budget.html`** (approved 2026-07-31).

### 7.1 Icon
GitHub mark left of "Add repo". `healthy` → `colorScheme.outline` (indistinguishable
from its neighbours); `warm` → `kStatusWarning`; `critical`/`paused` → `kDiffDel`,
paused adds a slash; `unknown` → dimmed. Hover → one-line tooltip
(*"quota runs out in 18 min · 1,769 REST left · click for detail"*).

### 7.2 Popover (click, not hover)
Collapsed: headline `18` + "min of quota left", burn caption, one bar per active
bucket (stacked green = makit / violet = other tools), attribution legend, throttle
banner, and a **"Burn history" pill** carrying a count of active throttles.
Expanding the pill reveals the 60-minute sparkline and the degradation ladder with
its thresholds. **Expanded state persists** across opens and restarts.

### 7.3 Search row
Rendered **only when the search bucket is non-idle**. It is a *per-minute* limit, so
it gets a ticked track and a seconds countdown (`24 / 30 this minute · 38s`) rather
than an hourly drain bar. makit never searches — a non-zero search bucket is itself
information (something else is on your token).

### 7.4 Explainer tooltips
Every number and every coloured mark carries a tooltip that explains *why it matters*
rather than restating its label (full copy in the mockup, §6 of that file). ~600ms
delay, wrapped.

### 7.5 Stale PR pills
`pr.stale` renders the existing pill at reduced opacity with a tooltip naming the
reason. The pill **never disappears** because of a failed lookup.

## 8 · Test plan (TDD — failing test first, per AGENTS.md)

Pure units carry the load; the gateway is tested with an injected `exec`.

| Unit | Cases |
|---|---|
| `budget.ts` | rate_limit parse; `others` derivation; burn from ring buffer; `msUntilEmpty`; level thresholds; unknown when unmeasured |
| `router.ts` | picks graphql when cheap; flips to REST when graphql starved; hysteresis blocks flapping; **no failover under secondary limit**; reset-imminence prefers waiting; `omit` for unresolved when graphql dry |
| `policy.ts` | each ladder rung; reserve withheld from background but not interactive; concurrency drop on secondary limit |
| `gateway.ts` | dedupes concurrent identical calls to one exec; TTL hit avoids exec; interactive bypasses TTL; 403 → `unknown` + budget refresh; spend counted before exec |
| `pr_watcher` | **`unknown` does not broadcast a drop** (regression guard for the reported bug); `none` does; signature unchanged across `unknown` |
| `repo_service` | `unknown` retains prior PR and marks `stale`; `none` clears |
| app: `codec` | decodes `github.budget`; tolerates missing buckets |
| app: widget | icon colour per level; popover collapsed/expanded; search row hidden when idle; stale pill dimmed |

## 9 · Risks

| Risk | Mitigation |
|---|---|
| No ETags (non-goal §3) means we cannot revalidate for free | Saving must come from TTL + dedupe + the 5s→30s interval; measure before/after call counts in the gateway's own counters |
| REST fallback costs 4× and could drain `core` fast | Router's score is *relative headroom*, so it only fails over when core genuinely has room; hysteresis prevents oscillation |
| `others` attribution is derived, not observed — a miscount looks like other tools | Label it as such in the UI copy; never gate behaviour on `others` alone |
| Cache staleness could mask a real PR change | 20s TTL is below the current 5s poll only in the throttled case; `interactive` always bypasses |

## 10 · Success criteria

1. With 10 tracked branches idle for 10 minutes, GitHub calls drop by **≥80%**
   versus today (measured by the gateway's own counter).
2. Forcing a 403 in a test leaves every PR pill **present and dimmed**, never removed.
3. The footer icon reflects quota within 60s of a change, and the popover opens with
   **zero** additional GitHub calls.
4. `pnpm test`, `pnpm typecheck`, `flutter analyze --fatal-infos`, `app/tool/audit.sh`
   all clean.
