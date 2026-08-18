# SPEC-performance-metrics-dashboard — Implementation plan

Spec: [`20260803-003700-SPEC-performance-metrics-dashboard.md`](./20260803-003700-SPEC-performance-metrics-dashboard.md)
Mockup: [`mockups/performance-dashboard.html`](../../mockups/performance-dashboard.html)

Ground rules (AGENTS.md): failing test first, SOLID/YAGNI, surgical diffs,
`server/` is pnpm-only, `flutter analyze --fatal-infos` clean.

## Phase ordering

```
Phase 1 (parallel, pure units, zero deps)
  T1 proc_table.ts    T2 tree.ts + ledger.ts    T3 ring.ts    T4 self.ts + wire_meter.ts
                                   │
Phase 2 (needs 1)
  T5 collector.ts
                                   │
Phase 3 (parallel, needs 5)
  T6 protocol + codec + ws/commands/metrics.ts + server.ts wiring
  T7 agent pids (child_transport → acp/codex → Session)      ← independent of T6
                                   │
Phase 4 (needs 6)
  T8 app: models + codec + store + watch controller
                                   │
Phase 5 (parallel, needs 8)
  T9  app: Tier 1 footer button + popover + frame timings
  T10 app: Tier 2 dashboard overlay + charts + export
```

T1–T4 are pure and can be built by four agents in parallel. T7 touches only the
adapter chain and can land before T6 if convenient — until then the collector's
`agents` closure simply returns `[]`, which the tests already cover.

---

## T1 · `server/src/metrics/proc_table.ts`

One `ps` exec per tick, parsed into a table.

```ts
export interface ProcRow { pid: number; ppid: number; rssBytes: number; cpuSeconds: number; comm: string; }
export function parseProcTable(stdout: string): Map<number, ProcRow>;
export async function readProcTable(exec: Exec, timeoutMs?: number): Promise<{ ok: boolean; table: Map<number, ProcRow> }>;
```

- Command: `ps -axo pid=,ppid=,rss=,time=,comm=`. Empty `=` suffixes suppress
  headers on both macOS and Linux.
- `rss` is **KiB** on both platforms → `rssBytes = kib * 1024`.
- `time=` parsing must accept **all** of: `mm:ss`, `mm:ss.cc`, `hh:mm:ss`,
  `dd-hh:mm:ss`. This is the single most platform-divergent field.
- A row that does not parse is **skipped, not fatal** — one weird `comm` (a process
  name containing spaces is normal) must not destroy the whole table.
- `comm` may contain spaces: split the line into exactly 4 leading fields and take
  the remainder as `comm`.
- `exec` is injected with the same shape as `git.ts`'s `run`, so production reuses
  `run` and tests never spawn.

**Tests:** fixture strings captured from macOS and Linux `ps` (commit them as
constants in the test, not files); each `time=` shape at a known second value;
`comm` with spaces; a garbage row skipped while its neighbours survive; empty
output → empty map (not a throw).

---

## T2 · `server/src/metrics/tree.ts` + `ledger.ts`

Whole-tree attribution and the churn-proof CPU accumulator. Both pure.

`tree.ts`:
```ts
export function childIndex(table: Map<number, ProcRow>): Map<number, number[]>;
export function descendants(index: Map<number, number[]>, root: number): number[];  // includes root
export function sumTree(table, index, root): { rssBytes: number; procs: number };
```
- `sumTree` deliberately returns **no `cpuSeconds`**: summing only this tick's pids
  loses every short-lived child, which is what the ledger exists to prevent. Two
  functions returning a differently-meaning `cpuSeconds` is a trap — CPU comes from
  the ledger, exclusively.
- An **unknown root returns zeros before traversal.** An absent pid can still be the
  `ppid` of an orphan, and walking the index would attribute that stranger's whole
  subtree to a dead agent (found in review).
- Build the index **once per tick** and pass it to every root (decision 3).
- `descendants` must be **cycle-safe** (a `visited` set). A ppid cycle should not
  exist, but a hang here would freeze the server.
- An unknown root → `{0, 0, 0}`, not a throw.

`ledger.ts` — decision 4, the subtle one:
```ts
export class CpuLedger {
  /** Fold this tick's tree into the root's monotonic total. */
  observe(root: number, pids: number[], table: Map<number, ProcRow>): number; // → cpuSeconds
}
```
- Per root, keep `{ base: number, live: Map<pid, {seconds, comm}> }`.
- Total = `base + Σ live`. When a pid disappears from the table, bank its final
  reading into `base` and **drop its entry** — that keeps the total monotonic when
  ripgrep exits *and* keeps `live` O(tree size). (The first implementation kept a
  frozen entry for every pid ever seen, which review caught as an unbounded map in
  the one feature that claims makit is cheap.)
- A pid **reused** by the OS is detected by a *dropped* cumulative CPU time or a
  changed `comm` — a single process's CPU cannot fall and its name cannot change.
  Bank the previous owner into `base`, then count the newcomer fresh: neither lost
  nor double-counted. Deleting the credit instead makes the total *drop*, which the
  collector would render as a **negative CPU%**.
- Never decrease the returned total; assert this in the test, including across reuse.
- Provide `dispose(root)` / `retainOnly(liveRoots)`: without them a server that has
  spawned and killed many sessions keeps one state object per dead pid forever.

**Tests:** forest with 3 levels; an orphan (ppid not in the table); a cycle;
`sumTree` totals; **ledger monotonic across a vanished child** (the mutation test:
remove the frozen-contribution line, confirm the total drops → red); pid reuse with
a changed `comm` does not double-count.

---

## T3 · `server/src/metrics/ring.ts`

```ts
export class Ring<T extends { ts: number }> {
  constructor(capacity: number);
  push(v: T): void;
  toArray(): T[];               // oldest first
  sinceMs(now: number, ms: number): T[];
}
```
Fixed array + write cursor; no `Array.shift` (O(n) per tick at 1 Hz is silly).

**Tests:** rollover preserves order; `sinceMs` boundary inclusive/exclusive stated
and tested; capacity 1 and 0 do not crash.

---

## T4 · `server/src/metrics/self.ts` + `wire_meter.ts`

`self.ts` — this process, exactly, without `ps`:
- `rssBytes` from `process.memoryUsage.rss()` (the cheap accessor form).
- CPU from `process.cpuUsage()` deltas: `(user+system) µs ÷ Δwall µs × 100`.
- Event loop: **one** `monitorEventLoopDelay({ resolution: 10 })` histogram, created
  once and `enable()`d for the process lifetime; read `percentile(50)/percentile(99)`
  in ns → ms, then `histogram.reset()` so each sample describes its own window
  (a lifetime histogram would flatten every spike into noise).
- Inject `now` and a `cpuUsage` fn so the rate is testable.

`wire_meter.ts` — pure counters:
- `addIn(bytes)`, `addOut(bytes)`, `frame()`, `sampleRates(now)` → per-second rates
  since the previous call, then reset.
- Deliberately byte counts of the **serialized frame**, taken where the transport
  already stringifies — no second `JSON.stringify` for accounting.

**Tests:** CPU percent arithmetic incl. `Δwall = 0` → `null`; percentile ns→ms
conversion; reset-per-window behaviour; wire rates over a synthetic 2 s window.

---

## T5 · `server/src/metrics/collector.ts`

The only stateful piece. Constructor exactly as in spec §Design.

- `start()` / `stop()`; `setWatchers(n: number)` chooses the cadence
  (`n > 0 ? watchedIntervalMs : idleIntervalMs`) and **re-arms the timer only when
  the interval actually changes** — otherwise a client toggling watch would reset
  the phase every time.
- Each tick: `readProcTable` → `childIndex` once → per-agent `sumTree` + `ledger` →
  `self` → `wire.sampleRates` → assemble → `ring.push` → `onSample(sample, {coarse})`.
- `storage` refreshed on `tickCount % 6 === 0`; otherwise carry `null` (the app
  keeps the last value it saw — the field is "steady state", not a rate).
- `cpuPercent` is `null` on the first tick after `start()` **and** on the first tick
  a given pid is seen (a new agent's first sample has no baseline).
- Sampler self-cost: measure the tick's own `process.cpuUsage()` delta around the
  work and report it in `sampler` — the panel's honesty row (decision 10).
- `historyFor(now)` → `ring.sinceMs(now, 30 * 60_000)`, used once per new watcher.
- A tick that throws (e.g. `ps` missing) must **log once and keep the timer alive**;
  a dead collector that never recovers is worse than a gap in the chart.

**Tests (fake timers, injected exec, zero subprocesses):** cadence 5 s → 1 s on
first watcher and back on last; interval unchanged → timer not re-armed; first
sample has `cpuPercent: null`; second sample computes the rate; a new agent
mid-stream gets `null` once; `storage` only every 6th tick; agents with
`pid: undefined` omitted; a throwing `exec` does not stop the collector; `turnActive`
derived from the agents closure.

---

## T6 · Protocol + codec + command + server wiring

Files: `protocol.ts`, `protocol/codec.ts`, `ws/client.ts`, `ws/auth_gate.ts`,
`ws/commands/metrics.ts` (new), `ws/commands/deps.ts`, `server.ts`.

1. `protocol.ts`: `EventKind |= "metrics.sample"`; the four DTOs from spec §Design,
   each with a doc comment saying **why it is not a session event** (mirroring the
   `github.budget` comment, so the next contributor does not "tidy" it into the log).
2. `protocol/codec.ts`: add `"metrics.sample"` to the top-level event kind list
   (line ~59, next to `"github.budget"`).
3. `ws/client.ts`: `watchingMetrics: boolean` and `readonly isLocal: boolean` on
   `WsClient`; `appPid?: number`.
4. `server.ts` `wss.on("connection")`: pass the already-computed `isLocal` into
   `makeClient`. In `ws.on("close")`: clear `watchingMetrics` and re-`setWatchers`.
   **This is the leak guard** — a panel closed by killing the window never sends
   `{on:false}`.
5. `auth_gate.ts` `handleHello`: `if (client.isLocal && typeof env.pid === "number")
   client.appPid = env.pid`. Non-loopback → ignored silently (decision 6). No new
   rejection path: a phone must still connect.
6. `ws/commands/metrics.ts`:
   ```ts
   r.register("metrics.watch", async (ctx) => {
     ctx.ack();
     ctx.client.watchingMetrics = ctx.env.on === true;
     deps.onMetricsWatchersChanged();
     if (ctx.client.watchingMetrics) deps.sendMetricsHistory(ctx.client);
   });
   ```
   Register in `buildCommandRouter` alongside `registerGithubCommands`.
   Extend `CommandDeps` with `onMetricsWatchersChanged()` and
   `sendMetricsHistory(client)`.
7. `server.ts`: construct the collector once; `agents` closure =
   `manager.allSessions()` filtered to sessions with an `agentPid`, mapped to
   `{sessionId, label, pid, inTurn}`; `app` pid = the first `authed && isLocal`
   client's `appPid`; broadcast `onSample` to `authed && watchingMetrics` clients
   (coarse frames go to **all** authed clients so the icon works without watching).
8. Wire meter: increment `addOut` where the client serializes a frame and `addIn`
   in `ws.on("message")` with `raw.length`. One line each; no new abstraction.
9. `metrics.background` preference is server-side config for now — read from
   `process.env.MAKIT_METRICS_BACKGROUND !== "0"` in P1 and promoted to a real
   setting in T9 if Q1 resolves that way. **Do not** invent a settings channel here.

**Tests:** `server.test.ts` —
- `metrics.watch {on:true}` acks, then a `metrics.sample` frame with `history`
  arrives; a second sample has no `history`.
- A non-watching client receives coarse frames but no watched ones.
- Socket close clears the watcher (assert cadence back to idle via a spy).
- `hello {pid}` from a non-loopback connection leaves `appPid` unset.
- **Regression guard:** after driving several samples, every session's `events`
  array is unchanged and `hub.fanout` was never called with a `metrics.*` kind.

---

## T7 · Agent pids

Files: `adapters/child_transport.ts`, `adapters/acp.ts`, `adapters/codex.ts`,
`session.ts`.

1. `ChildLineTransport` gains `readonly pid: number | undefined`;
   `spawnLineProcess` returns `child.pid` (already in hand at line ~126, currently
   discarded).
2. `acp.ts:684` and `codex.ts:896` keep the transport reference and expose
   `agentPid`. **Do not** add a new adapter method to the base class if only these
   two spawn — a getter on each is smaller than a contract change (YAGNI).
3. `session.ts`: `get agentPid(): number | undefined` delegating to the adapter,
   `undefined` when the adapter has none (the in-process `StubAdapter` in
   `test/e2e-server.ts`).

**Tests:** `child_transport` test asserts `pid` is set for a real trivial spawn
(`node -e ""` — already the pattern in that suite) and `undefined` after a spawn
fault; `session.test.ts` asserts `agentPid` is `undefined` for the stub adapter.

---

## T8 · App: transport + store

Files: `app/lib/store/metrics.dart` (new), `app/lib/transport/codec.dart`,
`app/lib/store/store.dart`, `app/lib/store/connection.dart`,
`app/lib/store/fake_server.dart`.

- Models: `MetricsSample`, `SurfaceMetrics`, `AgentMetrics`. `cpuPercent` is
  `double?` — **not** defaulted to 0 (decision 2).
- `codec.dart`: `case 'metrics.sample'` → `MetricsSampleFrame(sample, history)`;
  missing `app`/`storage` → `null`; garbage numeric → `_warn` + skip, matching the
  file's existing tolerance style.
- `store.dart`: a bounded list (cap 1800, drop-oldest) plus
  `metricsProvider` / `metricsHistoryProvider`. `history` on a frame **replaces**
  the list; subsequent samples append.
- `connection.dart`: add `'pid': pid` to the two authenticated `helloBody` maps
  (lines ~235 and ~288) — desktop only, from `pid` on `dart:io`'s `ProcessInfo`…
  which does not expose it, so use `io.pid` (`dart:io` top-level `pid` getter).
  Guard with `if (!kIsWeb && isDesktop)`.
- `MetricsWatchController`: **ref-counted** `watch()`/`release()` so the popover and
  the dashboard being open simultaneously send exactly one `{on:true}` and only
  release on the last close.
- `fake_server.dart`: emit a plausible sample every second so widget tests and the
  keyless stub loop render real charts.

**Tests:** codec decode with absent `app`, absent `storage`, garbage numbers,
missing `agents`; store replaces on `history` and appends after; cap enforced;
watch controller ref-counting (2 watch → 1 send; 1 release → no send; 2nd release →
`{on:false}`).

---

## T9 · App: Tier 1 footer button + popover

Files: `app/lib/desktop/metrics/metrics_button.dart`,
`app/lib/desktop/metrics/frame_timings.dart`,
`app/lib/desktop/metrics/charts.dart` (shared with T10),
`app/lib/desktop/chat/desktop_sidebar.dart` (`_Footer`, ~line 1088).

- Structural clone of `github_budget_button.dart`: `OverlayPortalController`,
  anchored popover clamped to the window, gesture dismiss, `Esc`.
- Placement: **left of** `GithubBudgetButton`. Same `VisualDensity.compact` +
  `BoxConstraints(minWidth: 32, minHeight: 32)`.
- Icon: `PhosphorIconsLight.pulse`, size 18. Colour per the spec's state table —
  theme tokens only (`outline`, `kStatusWarning`, `kDiffDel`). **No tint while
  working** (decision 12); the working state animates the glyph instead.
- `metricsIconStateProvider` computes the state from the latest sample; keep it a
  **pure function** of `(sample, elevatedSince)` in its own file so the state table
  is unit-testable without a widget.
- `frame_timings.dart`: `addTimingsCallback` into a 600-frame ring → p50/p95/dropped
  (> 16.7 ms). Registered on watch, **removed on release** — assert this, a leaked
  callback is a permanent cost.
- Popover per mockup §3, including the History expander (persisted like
  `sidebarArchivedProvider`) and the self-cost row.

**Tests:** icon colour per state incl. the no-tint working case; `—` rendered for
`cpuPercent: null`; agent rows sorted by RSS and two-line labels not overflowing at
300 pt; popover opens/dismisses; timings callback added on watch and removed on
dispose (count the registrations).

---

## T10 · App: Tier 2 dashboard overlay

Files: `app/lib/desktop/metrics/metrics_dashboard.dart`,
`app/lib/desktop/metrics/metrics_export.dart`,
`app/lib/desktop/settings/settings_window.dart` (`DesktopWindowBody`).

- `metricsDashboardOpenProvider` (`StateProvider<bool>`) + a second overlay in
  `DesktopWindowBody`, modelled on `settingsOpenProvider`.
- **Unlike Settings, do not `ExcludeFocus`/`ExcludeSemantics` the chat** — you must
  be able to drive a session while watching its cost.
- **Single-overlay invariant:** opening Settings sets the dashboard flag false and
  vice versa. Put this in the providers, not in two call sites.
- Six cells per mockup §5 + the process table. `CPU-s` column present and labelled
  as the optimisation target.
- `charts.dart`: `StackedAreaPainter`, `MultiLinePainter`, `HistogramPainter`.
  Painters interpolate on **`ts`**, not index, so the 5 s → 1 Hz cadence seam does
  not distort the x-axis.
- `metrics_export.dart`: `toJson()` of the whole ring + machine/version header, and
  a markdown summary. Pure functions; the file write is a thin caller.

**Tests:** each painter with an empty ring, one sample, and a full ring (golden-free
— assert no exception and the computed path bounds); dashboard renders every cell
with `app == null` (phone-only case); export JSON round-trips and the markdown
contains the headline numbers; single-overlay invariant.

---

## Verification (every task)

```sh
cd server && pnpm typecheck && pnpm test
cd app && /Users/le/Work/Vibe/flutter/bin/flutter analyze --fatal-infos && \
          /Users/le/Work/Vibe/flutter/bin/flutter test
cd app && ./tool/audit.sh
```

**End-to-end (keyless), after T6:**
```sh
cd server && pnpm exec tsx test/e2e-server.ts --mode stub --project <path>
# drive with a WSS client: hello{bearer:"e2e-token"} → cmd metrics.watch{on:true}
# expect: one frame with `history`, then ~1/s frames; the stub session is OMITTED
# from `agents` (no pid) — that is the correct behaviour, not a bug.
```

**Final acceptance** — the spec's four success criteria, plus the cost check:
with the dashboard open, the `sampler` row must read ≤ 0.5% CPU. If our own meter
cannot stay inside the budget, the feature contradicts the claim it exists to prove
and must be re-cadenced before merge.

## Resolve before P1

Q1 (background sampling default), Q2 (Elevated threshold — measure a real idle
makit first), Q3 (comparison banner in or out of v1). Q2 in particular should be a
measured number in the PR description, not a guess carried from the mockup.
