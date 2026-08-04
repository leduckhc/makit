# SPEC-37 — Performance dashboard (prove the efficiency claim, then optimise against it)

**Status:** Draft · **Priority:** P2 · **Branch:** `feat/performance-metrics`
**Depends on:** SPEC-32 (footer popover + top-level broadcast-event precedent), SPEC-19 (`ws/commands/*` registry), SPEC-29 (live session registry), SPEC-13 (in-window overlay surface)
**Mockup:** [`mockups/performance-dashboard.html`](../../mockups/performance-dashboard.html)

**Scope:** new `server/src/metrics/` (7 files), new `app/lib/store/metrics.dart`,
new `app/lib/desktop/metrics/` (button + dashboard + frame timings), plus surgical
edits to `server/src/protocol.ts`, `protocol/codec.ts`, `server.ts`,
`ws/client.ts`, `ws/auth_gate.ts`, `adapters/child_transport.ts`,
`adapters/{acp,codex}.ts`, `session.ts`, `app/lib/transport/codec.dart`,
`app/lib/store/connection.dart`, `app/lib/desktop/chat/desktop_sidebar.dart`,
`app/lib/desktop/settings/settings_window.dart`.
**Desktop-only** (no mobile UI). No new dependencies on either side.

---

## Goal

makit's pitch is that it is cheap: a Node server that forwards bytes, agents that
sit at 0% while parked, and a UI that stays at 60 fps while an agent burns a core.
That claim is currently unverifiable — by a user, by a contributor, and by us.

Make it **checkable in the product**, and make the same numbers the target for
optimisation work:

1. A user can answer *"what is makit costing me right now?"* in **one click** from
   the sidebar footer, and *"where did it go?"* in **two**.
2. Every number is attributable to a **surface** (app / server / one named agent)
   and to a **process id** a user can cross-check in Activity Monitor.
3. The measurement is **honest under scrutiny**: correct CPU semantics, whole
   process trees, and a stated cost for the measurement itself.
4. Turning the feature off costs nothing: with nobody watching, makit does at most
   one `ps` exec every 5 s, and zero bytes are written to disk — ever.

Success is behavioural: given a build regression that doubles idle CPU, this
feature surfaces it **without** anyone opening a profiler.

## Background — why the naive version produces numbers that flatter us

Three traps decide whether this ships as evidence or as decoration. Each is a
locked decision below.

### 1. `ps -o %cpu` is a lifetime average, not current CPU

`%cpu` is *(total CPU time) / (elapsed time)* since the process started. An agent
that pinned a core for 3 s and then idled for ten minutes reports **~0.5%**, and
keeps reporting it. Sampling `%cpu` would render the whole dashboard a lie in our
own favour — strictly worse than shipping nothing.

We must read **cumulative CPU time** (`ps -o time=`) and compute
`Δcpu ÷ Δwall × 100` between ticks. The first sample after a subscription
therefore has **no CPU value** (`null`, rendered as `—`), because a rate needs two
points. Do not paper over this with a zero.

### 2. An agent is a process *tree*, not a process

`pi` and `codex` spawn bash, ripgrep, node, language servers. In the mockup's
worked example, the codex root is ~180 MB while its tree is **1.22 GB** — charging
only the direct child under-reports by 7×.

Attribution is therefore: one `ps -axo pid=,ppid=,rss=,time=,comm=` exec per tick
→ build the ppid index **once** → sum descendants per agent root. One exec covers
every process on the machine; **never one exec per pid** (that is a fork storm
that would itself distort the reading).

A consequence that must be handled, not ignored: **short-lived children exit
between ticks.** A turn that spawns fifty ripgreps would show almost no CPU if we
only diffed pids present in both samples. See decision 4 (per-pid credited-so-far
ledger).

### 3. The meter must not distort the measurement

A 1 Hz sampler, a `ps` fork, a push frame per tick, and a row appended to the
SQLite event log would burn a visible slice of the efficiency being claimed. So:

- 1 Hz **only** while a subscriber is watching; 5 s otherwise; zero when disabled.
- **Never** persist a sample. The event log is append-only and replayed in full on
  resume (see `protocol.ts` `EventKind` notes); a per-second row would grow it
  without bound and slow every resume. Ring buffers in memory only.
- The panel **shows its own cost** as a metric. A meter that hides its overhead is
  not evidence.

### 4. Dart has no self-CPU API

`ProcessInfo.currentRss`/`maxRss` give the app's memory for free. There is no
CPU equivalent, and a platform channel for one is a poor trade.

Instead: the app sends its own **`pid`** in the `hello` frame, and the server —
which on desktop is the same machine — samples it with the same collector as
everything else. One code path, no platform channel, and the app row's CPU is
computed exactly like an agent's.

This must not be spoofable into a "sample any pid you like" primitive: the pid is
accepted **only from a loopback socket** (`server.ts` already computes `isLocal`
per connection). A phone on the tailnet reports no pid, and its row is simply
absent — the dashboard describes the *host*, not the viewing device.

## Design

### Server: `server/src/metrics/`

| File | Responsibility | Purity |
|---|---|---|
| `proc_table.ts` | `parseProcTable(stdout)` → `Map<pid, ProcRow>`; `readProcTable(exec)` runs the one `ps` | parser pure |
| `tree.ts` | `childIndex(table)`, `descendants(index, root)`, `sumTree(...)` → `{rssBytes, cpuSeconds, procs}` | pure |
| `ledger.ts` | per-pid credited-CPU ledger → monotonic `cpuSeconds` per root across child churn | pure |
| `ring.ts` | fixed-capacity ring buffer (`push`, `toArray`, `sinceMs`) | pure |
| `self.ts` | this process: `memoryUsage.rss()`, `cpuUsage()` deltas, `monitorEventLoopDelay` percentiles | thin |
| `wire_meter.ts` | WS bytes/frames in+out counters, per-second rate | pure |
| `collector.ts` | cadence, rings, sample assembly, `onSample` emitter | injected timers + exec |

`collector.ts` is the only stateful piece and takes everything by injection:

```ts
new MetricsCollector({
  exec,                     // (cmd, args) => Promise<string>   — same shape as git.ts `run`
  now: () => number,
  setTimer, clearTimer,
  self: SelfProbe,          // self.ts
  wire: WireMeter,
  agents: () => AgentPid[], // () => [{ sessionId, label, pid }]  — reads manager, no import
  storage: () => Promise<{ eventLogBytes: number }>,  // fs.stat, sampled every 6th tick
  watchedIntervalMs: 1_000,
  idleIntervalMs: 5_000,
  ringCapacity: 1_800,      // 30 min at 1 Hz; mixed cadence is fine — samples carry `ts`
})
```

`agents` is a **closure**, not a manager reference: `metrics/` never imports
`manager.ts`, so the dependency points inward and the collector is testable with a
literal array.

### Agent pids

`ChildLineTransport` gains `readonly pid: number | undefined` (already available as
`child.pid` in `spawnLineProcess`, currently discarded). `acp.ts` and `codex.ts`
surface it; `Session` exposes `agentPid`; `server.ts` builds the `agents` closure
from `manager.allSessions()`.

`pid` is `undefined` for a failed spawn and for the in-process `StubAdapter`
(`test/e2e-server.ts`) — such sessions are **omitted** from the per-agent list
rather than reported as 0.

### Wire protocol

One new top-level event kind, following SPEC-32's `github.budget` precedent
exactly — metrics are **host-wide**, not session-scoped, and must stay out of the
append-only session log.

```ts
type EventKind = … | "metrics.sample";

interface MetricsSampleDTO {
  ts: number;                       // epoch ms
  app: SurfaceDTO | null;           // null until a loopback client reports a pid
  server: SurfaceDTO & { eventLoop: { p50: number; p99: number }; };
  agents: AgentMetricsDTO[];
  wire: { inBytesPerSec: number; outBytesPerSec: number; framesPerSec: number };
  storage: { eventLogBytes: number } | null;   // refreshed every 6th tick
  sampler: { cpuPercent: number | null; rssBytes: number };  // our own cost
  turnActive: boolean;              // any session mid-turn — drives the icon
  procTableOk: boolean;             // false = `ps` failed; agents/app omitted because
                                    // we could not look, NOT because they exited
}

interface SurfaceDTO { pid: number; rssBytes: number; cpuPercent: number | null; cpuSeconds: number; }
interface AgentMetricsDTO extends SurfaceDTO {
  sessionId: string; label: string; procs: number; uptimeMs: number; inTurn: boolean;
}
```

The event payload is `{ sample: MetricsSampleDTO; history?: MetricsSampleDTO[] }`.
`history` is present **only** on the first frame after `metrics.watch {on:true}`,
so a freshly-opened panel draws a populated chart immediately (the same trick as
`GithubBudgetDTO.history`, but out-of-line because the ring holds full samples).

`cpuPercent` is `null` — never `0` — when no rate is computable yet.

`procTableOk: false` means the `ps` read failed. The agent rows and the app row are
then **omitted**, because with no process table there is nothing honest to say: a row
of zeros reads as "idle" and a missing row reads as "exited". The UI must render
*measurement unavailable* — it knows from the sessions snapshot that agents exist, and
silently dropping their rows is precisely how SPEC-32's PR pills used to vanish under
rate limits. The server row stays valid throughout: it comes from
`process.memoryUsage()`, not from `ps`.

### Subscription: a command, not a `sub` flag

`sub` is session-scoped (`SubscriptionHub.handleSub` requires a `sessionId`), so
overloading it would mean teaching the hub about a non-session subscription.
Instead, mirror `github.refresh`/`github.pause`:

```
cmd metrics.watch { on: boolean }
```

- `ws/commands/metrics.ts` registers it; `WsClient` gains `watchingMetrics: boolean`.
- On the first watcher the collector switches to 1 Hz; on the last unwatch (or that
  client's `close`) it drops back to 5 s. **`ws.on("close")` must clear the flag** —
  a closed panel that never sent `{on:false}` would otherwise pin 1 Hz forever.
- Samples fan out only to `authed && watchingMetrics` clients.
- The **icon** does not need a watcher: the coarse 5 s cadence broadcasts a
  *reduced* sample (see below) so the footer mark can show state without anyone
  opening anything.

Coarse-cadence frames omit `history`, `storage` (except every 6th) and the agent
`procs`/`uptimeMs` fields — they exist to colour an icon, not to draw a chart.

### Background sampling is a preference

`metrics.background` (default **true**, 5 s) drives the icon. Turned off:
sampling stops entirely, the icon renders the **Off** state, and opening the
popover starts a watched session on demand (with an empty history — honest, and
the tooltip says so).

### App

| File | Contents |
|---|---|
| `app/lib/store/metrics.dart` | `MetricsSample` + `AgentMetrics` models, ring in `StoreState`, `metricsProvider`, `MetricsWatchController` (sends `metrics.watch` on/off, ref-counted across the two surfaces) |
| `app/lib/transport/codec.dart` | `case 'metrics.sample'` → frame; tolerant of missing fields, matching the file's existing `_warn` style |
| `app/lib/desktop/metrics/frame_timings.dart` | `SchedulerBinding.addTimingsCallback` → p50/p95/dropped over a 600-frame ring. Registered **only while watching** |
| `app/lib/desktop/metrics/metrics_button.dart` | Footer `IconButton` + `OverlayPortal` popover — Tier 1. Structural clone of `github_budget_button.dart` |
| `app/lib/desktop/metrics/metrics_dashboard.dart` | Tier 2 panel |
| `app/lib/desktop/metrics/charts.dart` | `CustomPainter`s: stacked area, multi-line, histogram. **No chart dependency** |

Charts are hand-painted for the same reason SPEC-32's sparkline was: three shapes
do not justify a dependency, and `fl_chart` brings animation controllers we would
immediately have to fight (see decision 8).

### Tier 1 — footer popover

Left of `GithubBudgetButton` in `desktop_sidebar.dart:_Footer`, same
`VisualDensity.compact` + `BoxConstraints(minWidth: 32, minHeight: 32)`.

Icon states — and the one that matters is what is **absent**:

| State | Trigger | Tint |
|---|---|---|
| Idle | no turn, total < 2% CPU | none (`outline`, like its neighbours) |
| Working | any session mid-turn | **none** — the glyph animates its pulse |
| Elevated | over budget for > 30 s **while no turn runs** | `kStatusWarning` |
| Pressure | an agent tree > 2 GB RSS, or event-loop p99 > 100 ms | `kDiffDel` |
| Off | `metrics.background` disabled, or no sample yet | `#5a5a5a` |

**Deliberately no colour for "busy".** If the icon tinted whenever an agent
worked it would be tinted all day and mean nothing. Colour is reserved for *cost
without work* — the only reading that should make a user look, and the only one
that indicates a defect.

Popover content (see mockup §3): headline total, three surface rows with
sparklines, a per-agent list (memory-sorted, two lines: name + `parked 12m · 1 proc`),
a comparison banner, a `History` expander (last 5 min stacked CPU, frame p95,
loop p99, wire, **and the panel's own cost**), and `Open dashboard →`.

### Tier 2 — dashboard as an in-window overlay

**Not a workspace tab.** `Tab` in `panes/split_node.dart` carries only a
`sessionId` (nullable = the empty placeholder); a non-session tab would require a
kind tag threaded through persistence, drag/drop, `findTab`, group membership
derivation (SPEC-30), auto-select and pruning. That is a large, risky change to
the workspace model in service of one panel.

Instead reuse the **Settings mechanism**, which already solves exactly this
problem: a `metricsDashboardOpenProvider` (`StateProvider<bool>`) and a second
overlay in `DesktopWindowBody`, so the chat underneath stays alive and opening is
instant with no page transition. Unlike Settings, the dashboard does **not**
`ExcludeFocus` the chat — you must be able to interact with a session while
watching what it costs, which is the entire point of Tier 3-style optimisation
work.

Cells per mockup §5: stacked CPU (turn bands), resident memory, frame-time
histogram, server responsiveness (loop p50/p99 + wire), disk/socket footprint, and
the process table whose `CPU-s` column is the optimisation target — instantaneous
CPU% flatters or damns depending on when you looked; cumulative CPU-seconds per
turn is stable and comparable between builds.

Footer: the sampler's own cost, `Set baseline`, and `Export snapshot` (JSON +
pasteable markdown). **Export is the only way a sample reaches disk**, and only at
the user's request.

### Non-goals

- **No `makit bench` / CI perf budget** in this spec. It is the right follow-up
  (a dashboard shows drift; a budget test prevents it) but it is a CLI + CI
  surface, not this one.
- **No baseline *diff* view** (Tier 3). `Set baseline` stores a snapshot and the
  export includes it; the side-by-side diff UI is deferred until the numbers have
  proven interesting.
- No mobile UI. No per-thread or flame-chart detail. No live process-tree graph —
  impressive, answers no question this panel exists to answer.
- No persistence of samples, no new event-log kind, no SQLite schema change.
- No Windows support (`ps` shape is POSIX; macOS + Linux only).
- No comparison baselines shipped as constants — the mockup's "1/6 of VS Code"
  banner needs a measured baseline, which lands with `makit bench`. Until then the
  banner is **absent**, not hardcoded.

## Decisions (locked)

| # | Decision | Rationale |
|---|---|---|
| 1 | CPU is `Δcpu-time ÷ Δwall`, from `ps -o time=`; **never** `ps -o %cpu` | `%cpu` is a lifetime average — see Background 1 |
| 2 | `cpuPercent` is `null` on the first sample, rendered `—` | A rate needs two points; a zero would be a fabrication |
| 3 | One `ps -axo` exec per tick, ppid index built once, descendants summed per root | Correct attribution at one fork per tick — see Background 2 |
| 4 | A **per-root CPU ledger** (`base + Σ live`) makes each root's `cpuSeconds` monotonic across child churn *and* pid reuse | Diffing only pids present in both samples loses every short-lived child. An exited pid's final reading is banked into `base` and its entry dropped, so the total never decreases and the live map stays O(tree size) rather than O(every pid ever seen) — an unbounded map would be a slow leak in the feature that claims makit is cheap. A recycled pid (detected by a *dropped* cumulative time or a changed `comm`) starts fresh on top of `base`, so the previous owner's CPU is neither lost nor double-counted |
| 5 | 1 Hz watched · 5 s background · 0 when disabled; **never** written to the event log | The meter must not distort the measurement — see Background 3 |
| 6 | The app's CPU comes from the **server** sampling the pid the app reports in `hello`, accepted **only on a loopback socket** | Dart has no self-CPU API; one code path beats a platform channel, and the loopback gate stops it becoming "sample any pid" |
| 7 | `cmd metrics.watch {on}`, not a `sub` flag; the flag is cleared on socket close | `sub` is session-scoped; a leaked flag would pin 1 Hz forever |
| 8 | Charts are `CustomPainter`, no chart package | Three shapes; SPEC-32's sparkline set the precedent |
| 9 | Dashboard is an **in-window overlay** (`DesktopWindowBody`), not a workspace tab | `Tab` holds only a `sessionId`; a kind tag would ripple through persistence, drag/drop, groups and pruning |
| 10 | The panel displays **its own cost** | Self-honesty is the strongest form of the claim, and it is falsifiable by the reader |
| 11 | Sessions with no pid (stub adapter, failed spawn) are **omitted**, not zeroed | A zero is indistinguishable from a genuinely idle agent |
| 12 | No colour for "working" | An always-on tint carries no information; colour means *cost without work* |
| 13 | A failed `ps` sets `procTableOk: false` and **omits** the agent/app rows; the UI says *measurement unavailable* | Zeros read as "idle", missing rows read as "exited". Neither is true, and the second is the SPEC-32 vanishing-pill defect wearing a new hat |

## Phases

Each phase ends green (`pnpm typecheck && pnpm test`; `flutter analyze
--fatal-infos && flutter test`; `app/tool/audit.sh`). TDD: the failing test
precedes the logic.

**P0 — Measurement core (pure, no wiring).** `proc_table`, `tree`, `ledger`,
`ring`, `self`, `wire_meter`.
→ *verify:* `ps` fixtures for macOS **and** Linux (the `time=` and `comm=` shapes
differ); tree sums against a hand-built forest incl. an orphan; ledger keeps
`cpuSeconds` monotonic across a vanishing child; rate arithmetic at
`Δwall = 0` (must not divide by zero); ring rollover.

**P1 — Collector + protocol + server wiring.** `collector.ts`, `metrics.sample`
DTO + codec kind, `ws/commands/metrics.ts`, `watchingMetrics` on `WsClient`
(cleared on close), `pid` accepted in `hello` behind `isLocal`, wire meter hooked
into send/receive, `agents` closure from the manager.
→ *verify:* cadence switches on first watch / last unwatch / socket close; only
watchers receive samples; `history` present exactly once; a non-loopback `pid` is
ignored; no sample is ever appended to a session's event log.

**P2 — Agent pids.** `ChildLineTransport.pid`, threaded through `acp.ts`,
`codex.ts`, `Session.agentPid`.
→ *verify:* a spawned session reports a pid; a failed spawn reports `undefined`
and is omitted from `agents`.

**P3 — App transport + store.** Models, codec case, ring, `metricsProvider`,
ref-counted `MetricsWatchController`, `fake_server.dart` emitting samples.
→ *verify:* codec tolerates absent `app`/`storage`/garbage; ref-counting sends
exactly one `{on:true}` for two open surfaces and `{on:false}` only when both
close.

**P4 — Tier 1 popover.** Footer button, five icon states, three sparklines,
agent rows, History expander, frame-timings collector.
→ *verify:* icon colour per state (incl. *no* tint while working); `cpuPercent:
null` renders `—`; popover opens/dismisses; timings callback is registered only
while watching and unregistered on dispose.

**P5 — Tier 2 dashboard.** Overlay wiring, six cells, process table, export.
→ *verify:* charts paint with an empty ring, a single sample, and a full ring;
export JSON round-trips; the chat underneath stays interactive.

## Testing

- **Unit (server):** every P0 bullet; collector cadence with fake timers and zero
  subprocesses (injected `exec`).
- **Integration (server):** `server.test.ts` gains watch/unwatch/close cases, the
  loopback-pid gate, and a **regression guard** that no `metrics.*` event reaches
  `SubscriptionHub.fanout` or a session's `events` array.
- **Widget (app):** icon state matrix, popover content, dashboard cells under the
  three ring sizes, `—` for null CPU.
- **A11y:** each surface row and agent row carries a `Semantics` label with its
  numbers; the dashboard is keyboard-dismissible (`Esc`) like Settings.
- **Cost check (manual, recorded in the PR):** with the dashboard open, the
  sampler's own row must read ≤ 0.5% CPU on the dev machine. If our own meter
  cannot stay under budget, the feature contradicts the claim it exists to prove.

## Risks

| Risk | Mitigation |
|---|---|
| **CPU semantics wrong → every number flatters us** | Decision 1 + rate tests at boundaries; the process table shows `PID` and `CPU-s` precisely so a user can cross-check us against Activity Monitor |
| Short-lived children vanish between ticks, hiding real cost | Per-pid credited ledger (decision 4); residual loss bounded by one tick and stated in the tooltip copy |
| An agent's root pid dies while still registered, and some orphan's `ppid` equals it | `sumTree` returns zeros for a root absent from the table **before** traversing the index — otherwise the dead root inherits that unrelated orphan's whole subtree (found in review; regression-tested) |
| Orphaned grandchildren reparent to `launchd`/`init` and leave the tree | Documented limitation: they are counted until reparenting, then lost. Not worth a `pidfd`/cgroup dependency on macOS |
| `ps` output shape differs across macOS/Linux (and `time=` uses `[dd-]hh:mm:ss` vs `mm:ss.ss`) | Fixture tests for both; the parser rejects unparsable rows individually rather than throwing away the table |
| The meter becomes the cost | Decision 5 + the self-cost row + the manual cost check in Testing |
| 1 Hz pinned forever by a client that closed without unwatching | Flag cleared in `ws.on("close")`, asserted in `server.test.ts` |
| A tick outliving its interval, so two ticks race the CPU baselines | The `ps` timeout bounds only the exec, not the whole tick, so the collector refuses re-entry while a tick is in flight (found in review; regression-tested) |
| Per-pid rate state accumulating across session churn | `cpuBaseline`/`firstSeenMs` are pruned to live pids every tick, and the ledger is pruned via `retainOnly` including the app root (found in review; leak-tested with 50 sessions) |
| **An adapter that never emits a terminal status pins `running`** | Then `turnActive` stays true, the icon animates forever and the **Elevated** state — "cost while *not* working" — can never fire, silently hiding the exact regression this feature exists to catch. Not currently guarded; the shared `TurnTracker` (`adapters/turn-status.ts`) is the single place that must always settle, and it is tested there |
| Reporting a pid becomes a "sample any pid" primitive | Loopback-only acceptance (decision 6) |
| Dashboard overlay competes with Settings for the same z-space | Both are `DesktopWindowBody` children; opening Settings closes the dashboard (single-overlay invariant, tested) |
| Charts drawn from a mixed-cadence ring look uneven at the 5 s → 1 Hz seam | Samples carry `ts`; painters interpolate on time, not index — tested with a ring that straddles a cadence change |

## Open questions

- **Q1 — background sampling default.** Spec assumes `metrics.background = true`
  at 5 s so the icon can carry state. The alternative (off until first open) makes
  the idle cost exactly zero but reduces the icon to decoration. Confirm before P1.
- **Q2 — Elevated threshold.** Spec assumes *> 2% total CPU sustained 30 s while
  idle*. That number should be measured on a real idle makit before it is frozen;
  if idle genuinely sits at 0.4%, 2% is a reasonable 5× headroom, but it is the
  one threshold that will produce false positives if wrong.
- **Q3 — comparison banner.** The mockup's "1/6 of VS Code + terminals" line is
  the most persuasive element and the least defensible without `makit bench`.
  Spec says omit it in v1. Confirm — or accept a measured-once-per-machine
  baseline as part of P5.
