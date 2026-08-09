# SPEC-47 — How long did that take: durations for tool calls, thinking, turns and sessions

**Status:** Draft · **Priority:** P2 · **Branch:** `feat/session-timings`
**Depends on:** SPEC-16/SPEC-19 (the event fold — `foldEvents`, `chat_items.dart`), SPEC-35
(mid-turn steering: a `steered` user message must not open a turn), SPEC-37 (`session.usage` —
the cost the turn receipt reports, and the popover the session rollup lands in), SPEC-21
(reversed lazy transcript — why nothing here may measure scroll or hold a per-row ticker).
**Design board:** [`mockups/session-timings.html`](../../mockups/session-timings.html) —
variants **1B + 1D, 2B, 3A, 4A + 4B, 5B** were chosen; the rejected ones are recorded in §8 there.

---

## Goal

Four scopes, and they are not one feature repeated four times — they answer different questions,
which is why they get different renderings:

| Scope | The question | Answered by |
| --- | --- | --- |
| Tool call, finished | "what ate those two minutes?" | a duration on the collapsed row, **only when it is worth saying** (D2) |
| Tool call, running | "is it working, or is it hung?" | a live counter beside the spinner, escalating past a minute (D6) |
| Thinking | "how long did it reason?" | `Thought for 12s` — the row's only structured fact (D7) |
| Turn | live: "is it alive?" · after: "what did that cost?" | the working indicator counts (D8); a dim receipt closes the turn (D9) |
| Session | "how much effort is in this branch?" | a rollup inside the existing usage popover (D11) |

Today the app can answer none of them. A tool call that took 200 ms and one that has been stuck for
18 minutes render **identically** — same row, same pulsing dot (`tool_call_card.dart:150`).

## What is already measurable, and the two fields that throw it away

This is not new telemetry. Every session event already carries `ts` (`protocol.ts:387`, set from
`Date.now()` at `record` time) and every `ChatItem` already keeps it (`chat_items.dart:31`). Three of
the four scopes are therefore **derivations over data the app already holds**:

- **Turn boundaries are already in the log.** `session.status` is emitted through `this.record`
  (`session.ts:437`), so it is persisted and replayed like any other event — `running → idle` edges
  are sitting in the stream the fold already walks. The server-side turn machine
  (`adapters/turn-status.ts`) is the thing producing them; nothing new is needed from it.
- **But the *end* timestamps are dropped on the floor.** `ToolCallItem.copyWith` and
  `ThinkingItem.copyWith` both re-use the *start* `ts` (they must — `ts` is `final` on `ChatItem`
  and the row's identity is its start). So `tool.call.end`'s and `agent.thinking`'s timestamps
  are parsed, matched to a card, and discarded. **Two new fields** fix it (D1).
- **Session age is the only thing needing the wire touched.** `Session.createdAt` exists, is
  assigned on construction and *is persisted* through `toMeta()` (`session.ts:147,209,311`) — it is
  simply missing from `SessionDTO` (`toDTO()`, `protocol.ts:570`). One optional field (D12).

## Why the durations are derived client-side, not sent by the server

A `durationMs` on `tool.call.end` looks tidier and is worse:

- **It would be a second source of truth that can disagree with the log.** The two timestamps are
  already persisted; a duration field computed at emit time is a *third* number that a replay cannot
  re-derive, so a bug in it is invisible and permanent in the event log.
- **It would not cover history.** Every transcript recorded before this spec has both timestamps and
  no duration field. Deriving means the feature works retroactively on the whole archive, for free.
- **Turns have no single emitter to put it on.** A turn is an *interval between two events*, one of
  which (`idle`) is emitted by the status tracker with no knowledge of what opened it.

## Why `formatDuration` cannot be reused, and why it is nonetheless left alone

`formatDuration` (`metrics_button.dart:1217`) and `portUptimeLabel` (`ports_vocabulary.dart:192`)
both exist. Neither fits: `formatDuration` renders every sub-second call as `0s` and collapses
`2m 41s` to `2m` — which is exactly the distinction a turn receipt exists to make.

The tempting move is to widen `formatDuration` and have all three callers share it. **Do not.** Those
two format *uptime* — a coarse, still-running "how long has this been up" where seconds are noise and
a day tier matters. This spec formats a *span that ended*, where sub-minute precision is the entire
point. Same units, different question. So: one **new** pure function, and the existing two are not
touched (D13). The boundary is written down here so review does not re-litigate it as duplication.

## Why nothing here may hold its own ticker

Measured previously and recorded in the perf notes: one shared low-rate clock beats N per-widget
tickers, and **animated widgets only tick inside the viewport** — an off-screen ticker does not run.
`PulseClock` (`app/lib/ui/widgets/pulse.dart`) is the sanctioned clock and is already what
`PulseSpinner` and `WorkingIndicator` use. A `Timer.periodic` per running row would cost more than the
cards it annotates.

But it is a **20 Hz** clock (`kPulseInterval = 50 ms`, `pulse.dart:13`) and `PulseBuilder` rebuilds its
subtree on *every* notification — the `period` argument only shifts the phase *value* it passes down,
it does not throttle anything. So the shared clock is the right *source* and `PulseBuilder` is the
wrong *consumer* for a text label that changes once a second. D5 derives a second-cadence notifier
from it instead: one timer for the app, one rebuild per displayed second.

The off-viewport behaviour is a *feature* here, not a caveat: a running row scrolled out of view stops
updating and catches up on its next build, because the elapsed value is computed from timestamps at
build time rather than accumulated.

---

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| **D1** | **Two new fields on the fold's items: `ToolCallItem.endedTs` and `ThinkingItem.lastTs`**, both `int?`, both set from the *ending* event's `ts` (`tool.call.end`; `agent.thinking`, or the last `agent.thinking.delta` for a still-streaming card). `ChatItem.ts` keeps meaning "when this row started" and stays `final`. `endedTs == null` means **"no terminal event was observed"** — which is *not* the same as "still running" (D6a). No new event kinds, no protocol change, no server-computed duration. | The end timestamps are already parsed and thrown away (see above); this is the minimum that stops discarding them. Separate fields rather than a computed `durationMs` because a *running* span has no end yet and must not carry a stale one. `lastTs` (not `endedTs`) on thinking because it advances on every delta: a streaming card's elapsed is honest mid-stream, and the final event just lands the last value. The null semantics are stated precisely because review caught the first draft conflating the two — see D6a. |
| **D2** | **A finished tool row shows a duration only at ≥ `kToolDurationFloor` (2 s).** Below it, the row is exactly what it is today. | Most tool calls are fast, so an always-on column is mostly `0.2s` — ink spent to say "nothing happened here". **Correction from the golden audit:** the first draft also argued the label is "taken from the one line that already ellipsizes", and at desktop width that is simply false — rendered at 720 pt no row truncates and roughly 600 px sits empty between the summary and the status glyph, so a duration there costs nothing. The width argument holds only on the phone, where it is in fact *stronger* than claimed (D2a). So this decision now rests on the noise argument, which is width-independent. Gating makes the label *mean something by appearing*, which is the same rule that makes `portUptimeLabel` return `''` and `ContextUsageRing` refuse to draw without a known window. Board §1A shows the alternative: six rows, one interesting number. |
| **D3** | **The exact figure is always available, in the expanded body** — a facts line above the tool output: `ran 2m 41.4s · started 14:02:14 · exit 1`. | This is what makes D2 safe: gating the collapsed label means you cannot distinguish "fast" from "not measured" at a glance, so the unabbreviated truth must be one tap away and *unconditional*. It also puts the started-at clock time somewhere, which is why no row needs an absolute-timestamp column (board §8). |
| **D2a** | **The phone's constraint is measured, not assumed: at 393 pt two of four real rows already ellipsize before any duration exists.** P1b must re-render the golden audit after the change and compare. | From the audit: `Read …/app/lib/store/chat_items.d…` and `Ran flutter test test/store --no-…` both truncate at 393 pt today. A trailing token takes roughly another 40 px from a line that has already run out. That does not by itself justify a second threshold (see Non-goals), but it does mean the phone rendering is a **verification requirement**, not a thing to eyeball once. |
| **D3a** | **The expanded body's facts go in a labelled section, matching the two the body already has.** | The audit shows the expanded body is not the flat text block the mockup drew: it renders titled sections (`Command`, `Error`) with copy buttons, and the header collapses to the bare verb (`Ran`). So D3's `ran … · started … · exit …` line has an obvious home and an existing visual grammar to match, and the expanded header has room to carry the duration beside the verb. |
| **D4** | **The collapsed row's duration also carries the standard one-sentence affordance** — tooltip on desktop, long-press bubble on mobile, and the same text in the semantics label. | Not a new pattern: SPEC-41 already fixed this rule for terse tokens (*"every terse token carries one sentence, shown as a tooltip on the desktop, a long-press bubble on the phone, and the screen-reader label on both"*). A bare `48s` is exactly such a token. |
| **D5** | **Every live counter is driven by a second-cadence notifier derived from the shared `PulseClock`** (a `ValueNotifier<int>` of whole seconds that listens to the clock and notifies only when the second changes), and computes elapsed from timestamps at build time, accumulating nothing. **No `Timer.periodic`, and no `PulseBuilder` wrapped directly around a duration label.** That notifier is also the **injectable clock seam** the widget tests drive. | Measured previously: one ticker for the app, and off-viewport tickers do not run. Computing from timestamps rather than incrementing is what makes the off-viewport pause harmless — a row that missed 200 ticks renders the right number on its next build. **Review correction:** the first draft said "reads the shared clock at ~1 Hz", which the mechanism does not do — `PulseClock` notifies every 50 ms (`kPulseInterval`, `pulse.dart:13`) and `PulseBuilder` rebuilds on *every* notification (`pulse.dart:95-128`); its `period` only shifts the phase *value* and throttles nothing. A label wrapped in `PulseBuilder` would rebuild 20×/second to produce identical text 19 of those times. The derived notifier keeps the property that actually matters (one timer for the whole app) while making the rebuild rate match the smallest unit displayed (D14). A seam is not optional: a duration label cannot be asserted against a real wall clock. |
| **D6** | **A running tool row keeps its spinner and gains a live counter to the left of it. Past 60 s the number takes `kStatusWarning`.** Escalation applies to **running tool calls only** — never to a turn timer or a thinking counter. | The spinner says "not finished" and cannot distinguish 2 s from 20 minutes; a number beside it is strictly more informative for one label's width. The spinner *stays* because that green pulse is shared vocabulary (`SessionStatusDot`, `_GroupLiveDot`) and carries the only `semanticsLabel: 'running'` on the row — board §2C drops both to save a glyph, which is a worse trade. Escalation is scoped because a long *turn* or a long *thought* is normal and a long *single tool call* is not: colouring all three teaches the user to ignore the colour. Colour is never the only signal — though a design review was right that the *number alone* does not convey “unusual” to a screen reader, which is why D17 puts the escalation in the semantics label too. |
| **D6a** | **A live counter freezes when the turn enclosing it closes.** A row with no `endedTs` whose turn was later closed by an `idle` renders the elapsed **at that `idle`**, static and dimmed — never a ticking number. | Without this the feature makes a *louder* false claim than the bug it inherits. ACP deliberately closes orphan tools at `endTurn` (`acp-map.ts:196-207`: *"a `tool.call.start` with no matching end leaves the row spinning forever"*), but codex's `endTurn()` only clears bookkeeping (`codex-map.ts:111-114`), so an aborted or crashed codex turn *can* leave a card with no end. Today that card spins forever; with a naive live counter it would climb past `47m` and keep climbing — a spinner is vague, but a number is a specific assertion, and that one would be false. The forever-spinner itself is **pre-existing** and out of scope (AGENTS.md §3: mention, do not fix); this decision only refuses to amplify it. |
| **D6b** | **A duration label uses tabular figures and reserves a minimum width** sized for the widest common form (`00m 00s`). | The trailing token and the summary it borrows width from share one line, and the summary sits in an `Expanded` that ellipsizes (`tool_call_card.dart:183-204`), so a proportional label growing `9s` → `10s` → `1m 04s` would re-ellipsize the summary on a tick. This is about text jitter, not scroll: the reversed transcript already corrects inside layout (`transcript_list.dart:160-179`), so SPEC-21 is not at risk here. |
| **D7** | **Thinking rows read `Thought for 12s` (leading), and `Thinking … 41s` while streaming. No threshold — a thinking row always shows its duration**, rounded up to a minimum of `1s`. | A collapsed thinking row has *no* summary; it is a truncated first sentence of the reasoning. The duration is therefore the only structured fact the row can offer — it is the row's label, not an annotation on it, which is also why it leads rather than trails. D2's threshold argument does not transfer: there is no summary being crowded out, and there is no other content competing for the leading edge. |
| **D8** | **The `WorkingIndicator` gains a live turn counter beside the shimmering word** (`Percolating 47s`). This is the *only* live turn timer — not the composer footer, not the sidebar. | It already sits at the tail of the transcript, is already on the shared clock, and is already the thing the eye goes to while waiting; this is the cheapest change in the spec and answers the question users actually ask. One place, not two: board §4D is genuinely better when you have scrolled away from the tail, but shipping both duplicates the number whenever you have not — and the composer footer is the space SPEC-40 just reclaimed. |
| **D9** | **A closed turn appends one dim receipt row** — a hairline plus `2m 13s · 14 tools`. A **`4m 12s waiting on you`** token in `kStatusCaution` is added **only when a gate actually blocked**. New fold item type, emitted at the closing edge. **No cost on the receipt** (D9a). | The transcript currently has no turn boundaries at all, so "which turn was slow" is unanswerable by scrolling — and a turn's wall clock is not recoverable from the rows, because the gaps *between* tool calls are model latency that no row represents. The gate token is conditional because on an ungated turn there is nothing to explain, and an unconditional `0s waiting on you` would be noise on the common case. Board §4C spells both readings out on every turn; that re-raises "which number is the real one?" eighteen times a session, so the headline is **wall clock** and the gate is a *subtraction you are shown when it applies*. **The tone is `colorScheme.onSurfaceVariant`** — not a dimmer custom grey (D9b) — and on a phone the row **stacks onto two lines** when the gate token is present (D9c). |
| **D9a** | **The per-turn cost token is cut.** The board (§4B) showed `· $0.08`; it is not built. | Two independent findings killed it. **It is not derivable where the spec put it:** `reduceEvent` handles `session.usage` by whole-snapshot replacement and **returns before appending it to `events`** (`store.dart:249-258`), so the event never reaches the list `foldEvents` walks — the fold structurally cannot see one usage snapshot, let alone two to difference. **And half the harnesses cannot price a turn anyway:** codex emits `session.usage` once per turn with token counts only — *"codex prices nothing, so there is no `cost` on this path"* (`codex-map.ts:84`). Getting the token would mean adding an ordered usage-snapshot history to the store plus an association rule, as new plumbing, so that one harness could show one number on one row. That is the trade YAGNI exists to refuse. Cumulative session cost is already one tap away in the usage popover, where it is measured rather than differenced. |
| **D9b** | **"Quiet" is achieved by size and whitespace, never by a dimmer colour. The receipt, and every de-emphasised duration, uses `colorScheme.onSurfaceVariant` — the dimmest tone the palette contains that still clears AA.** | A design review measured the tone used for "dim" at **3.57:1** on the transcript surface — under the 4.5:1 floor — while `onSurfaceVariant` (`#9E9E9E` in dark) measures **6.69:1**. **A golden-render audit of the real widgets then found that tone is not a mockup invention at all:** `#6f6f6f` is exactly what `cs.onSurfaceVariant.withValues(alpha: 0.65)` composites to, which is what `ThinkingLine` ships today (`chat_transcript.dart:244`). So the failure is **pre-existing in the app**, in one of the two widgets this spec modifies. An on-device run then showed the app follows **system appearance**, and the same row is *worse* in light: `_mutedLight` at 0.65 over `#FAFAFA` measures **2.76:1**. The same audit measured `WorkingIndicator`’s shimmer trough (`alpha: 0.18`) at **1.34:1** dark / **1.28:1** light — the "agent is alive" signal is effectively invisible for half of every sweep. So there is no headroom below the token: anything quieter than it is non-compliant, which means colour cannot be the de-emphasis channel at all. The receipt is therefore made quiet by **`labelSmall` (11 px) plus the hairline rule plus surrounding space**, and D9's word "dim" is replaced by a named token so an implementer cannot invent one. Note this is the same token the tool row's summary already uses (`tool_call_card.dart:194`), which is why the receipt reads as recessed anyway — it is smaller, not greyer. **Boundary:** the existing alpha-dimmed rows are a pre-existing violation of this same rule and are *mentioned, not fixed* (AGENTS.md §3). But D7 adds a label **to** that row, so the new `Thought for 12s` label takes `onSurfaceVariant` at **full opacity** — it must not inherit the 0.65 alpha, or the spec would be shipping a fresh 3.57:1 string. |
| **D9c** | **On a narrow surface the receipt stacks: line 1 `2m 13s · 14 tools`, line 2 the gate token.** | Measured on the board: the one-line form needs ~340 px once `· 4m 12s waiting on you` is appended, inside a 342 px content box at 390 pt — so it wraps at an arbitrary point or clips. Stacking is specified rather than left to `Wrap` because the break must fall between the two *thoughts* (what the turn cost / what you cost it), not wherever the text happens to run out. |
| **D6c** | **A duration label is `bodySmall` (12 px) beside the row's `bodyMedium` (13 px) summary, and takes `onSurfaceVariant` — the same colour as the summary.** De-emphasis is one **size** step, not a colour step. | The board used 11.5 px, which a typographic review correctly called "an accident, not a hierarchy": it is not on the app's scale at all (`bodySmall` is 12, `labelSmall` is 11 — `theme.dart:239-243`), and a 1.5 px delta against the row reads as a rendering artifact rather than intent. Colour cannot carry the de-emphasis for the reason in D9b, so size must. |
| **D21** | **Under `prefers-reduced-motion` (`MediaQuery.disableAnimations`), a live counter coarsens to a 5 s cadence rather than ticking every second; the exact figure still lands on the finished row.** | A number that changes every second is *visual motion* for a user with vestibular or attention sensitivity even though nothing moves — and the board shipped with no reduced-motion path at all (11 elements kept animating with the media feature active, caught by the design review). Coarsening rather than freezing keeps the one thing the counter exists for (proof the agent is alive) while removing the per-second flicker. This decision is also the answer to "is a counter motion?": yes, for this purpose. Note the pre-existing `PulseSpinner`/`WorkingIndicator` shimmer has the same gap; fixing *those* is out of scope (AGENTS.md §3) but this feature must not add to it. |
| **D22** | **Durations and clock times are kept in separate roles: the bubble's `18:03` says *when*, a duration says *how long*, and no row carries both.** The turn receipt therefore never prints a clock time, and `D3`'s `started 14:02:14` stays inside the expanded body where it is a detail rather than a column. | Discovered by running the app: the transcript already renders a clock time under every message bubble, so a receipt reading `2m 13s` will sit two rows from one reading `18:03`. Two time systems adjacent is fine as long as each answers a different question and they never compete for the same slot — which also means D3's started-at has precedent in the app rather than being a new idea. Had this spec been written from the mockup alone it would have introduced the duration vocabulary while asserting the app had none. |
| **D10** | **Turn boundaries, precisely: a turn opens at a `user.message` with `steered != true` (or, absent one, at the first `session.status: running`), and closes at the first `session.status: idle` after it — `idle` and nothing else. `awaiting-approval` / `awaiting-input` do NOT close a turn** — the interval from entering a gate to the next `running` — or to the closing `idle` when the turn settles while still gated — accumulates into `gatedMs`. An unclosed turn (the live one, a cancelled turn the harness never settled, a transcript that ends mid-turn) emits **no** receipt. Events preceding any opener attach to no turn. | Each clause is a trap that a naive `running → not-running` read falls into, and one clause is a trap that review caught (see "Verified against the real adapters" below). Gates emit real status events *inside* a turn, so the naive read ends the turn at the approval prompt and reports a fraction of it as the whole; a denied approval can also go straight from gate to `idle`, and that open gate is user-blocked time, not agent time. **`exited` is deliberately NOT a closer**: it is not a turn transition at all — `manager.ts:1421` records it when a *reattach fails*, so an agent that died mid-turn gets its `exited` stamped whenever the user next reopens the session, and closing on it would print `3d 4h` for a turn that ran thirty seconds. `steered` is load-bearing: SPEC-35 injects a mid-turn message that is a `user.message` in the log but explicitly *not* a new turn — without this clause every steer emits a phantom receipt and halves the real one. The `running`-fallback is for a **partial replay window** (D16's non-`_historyLoaded` tail), not for resume — a resumed session emits `idle`, not `running` (`codex.ts:222`, `acp.ts:272`), so resume never triggers it. No receipt for an open turn because a receipt is a *closing* statement; the live counter (D8) is what speaks for an open turn. |
| **D10a** | **A turn containing neither a tool call nor an agent message emits no receipt**, whatever its span. | Targets one real artifact rather than guessing at a floor: when `turn/start` throws, codex emits `session.error` and then `settleIdle()` (`codex.ts:250-257`), producing a complete `user.message → running → idle` bracket a few milliseconds wide. That is a *failed* turn, and `0s · 0 tools` describes it as a cheap successful one — directly under the error row that says otherwise. Gating on content, not duration, because a genuinely fast turn that did something ("yes, that's right") is honest and should still be receipted. One reviewer argued for cutting this and letting the error row speak alone; kept, because the *contradiction* is the problem — an error row and a success receipt describing the same turn is worse than either alone. |
| **D10b** | **A span that cannot be computed honestly is not rendered.** `endedTs < ts`, a negative elapsed, or a missing opener → no label and no receipt. Never a clamp to zero, never an absolute value. | Server clocks move (an NTP step, a laptop resuming from sleep mid-turn), and `ts` is `Date.now()` at record time rather than a monotonic counter, so `end < start` is reachable in a real log. Both `0s` and `\|Δ\|` are fabrications; absence is the honest rendering and is what this codebase already does — `portUptimeLabel` returns `''` for `ms < 0`. |
| **D11** | **The session rollup lives in the context-usage popover** (`app/lib/ui/composer/context_usage.dart`), as four rows below a divider: **Age**, **Agent time**, **Turns**, **Median turn**. No new chrome anywhere. `Agent time` is Σ(wall − gated); `Median turn` is over wall clock. | That panel's whole job is already "facts about this session", and this number is checked maybe once an hour — it does not deserve a permanent pixel. Two numbers instead of one because either alone lies: a session opened three days ago holding four minutes of agent time is described honestly only by both. Median, not mean — one 40-minute `gh pr checks --watch` wrecks a mean and the panel would report a typical turn that never happened. |
| **D12** | **`SessionDTO.createdAt?: number`** on the wire (populate from the existing persisted `Session.createdAt`) **and a matching `Session.createdAt` on the app model** — `app/lib/store/models.dart` has no such field today. **Absent → the `Age` row is not rendered** (never a fabricated age from an epoch-0 default). | The value already exists and is already persisted; only the DTO omits it. Optional on the wire so an older server pairs with a newer app without a fabricated "56 years" — the same absent-stays-absent rule `portUptimeLabel` is built on. The app-side field is called out because the first draft specified only the server half, which would have left `Age` unimplementable; note the app model uses `0` as its "unknown" for `lastActivityAt`, so `createdAt` must be **nullable** rather than following that pattern. |
| **D13** | **One new pure formatter, `formatElapsed(int ms)` returning `String?`** — the ladder in §6 of the board: `null` for a negative or unrepresentable span (D10b) · `2.4s` (one decimal, 2–10 s only) · `13s` · `2m 41s` · `18m 04s` (zero-padded) · `4h 12m` · `3d 4h`. **It must round exactly once, at the top, and use integer arithmetic for every tier below that** — and the decimal branch's bound is **9.95 s, not 10 s**. **`formatDuration` and `portUptimeLabel` are not touched.** | Rationale above: uptime and elapsed-span are different questions and the existing two are correct for theirs. The decimal exists only in the 2–10 s band because that is where it discriminates (`2.4s` vs `9.1s`); past ten seconds it is false precision. Zero-padding keeps a column of tabular numbers a column. `String?` rather than a `'—'` sentinel because D10b's rule is *not rendered*, and a nullable return makes that unrepresentable-by-accident (deliberately unlike `portUptimeLabel`, which returns `''`). **The round-once rule is not style — it is the fix for a real bug** (see D13a). |
| **D13a** | **`formatElapsed` must be TDD'd against these carry cases specifically: `59.5s`, `59.9s`, `119.7s`, `3599.7s`, `9.96s`, a negative span, and a non-representable one.** | The board's reference `fmt()` rounded *inside* each tier, so a value that rounded up to 60 escaped its tier: `59.5s → "60s"`, `119.7s → "1m 60s"`, and — because the carry **cascades a whole tier** — `3599.7s → "59m 60s"` instead of `1h 00m`. A non-finite input fell through every comparison to the day branch and printed nonsense. Found by `ocr review` on the mockup (high severity) and confirmed by running it. It is recorded as its own decision because **the boundary list in D13 does not catch it**: `2.4s`, `13s`, `2m 41s`, `18m 04s`, `4h 12m` all pass under the buggy algorithm, so a conscientious implementer testing exactly the documented ladder would ship the bug. `formatElapsed` operates on real millisecond spans, so `59500` and `119700` are not hypothetical. |
| **D14** | **Live labels never show sub-second values** (a running span reads `1s` until it is `2s`), and **the smallest unit any label shows is `1s`**. | A tenth ticking ten times a second is unreadable and would force the clock off 1 Hz (D5). Also keeps a running row's label from being *wider* than its finished one, which would reflow the row at the moment it completes. |
| **D15** | **The server clock is the only clock.** All spans are computed in server time; the app maintains a single `serverClockOffset` updated from the `ts` of each **live** event, and never from replayed history. | Every `ts` comes from the server's `Date.now()`, so mixing in the device clock makes a fresh tool call read `30s` on a phone whose clock is skewed. The live/replay seam already exists and is explicit: `_onFrame` buffers into `_replayBuffer` while `_awaitingReplay` holds the session and folds immediately otherwise (`store.dart:435`), so "live" is a branch that is already there — the offset is updated in that branch and **not** in `_flushReplay`. During a running turn events arrive at least every second (deltas), so the offset is fresh exactly when a live counter is on screen; while idle nothing is counting. |
| **D16** | **The rollup is only shown for a session whose full history this client holds**, which requires exposing that fact: `_historyLoaded` is private controller state (`store.dart:400-416`), set only in `_flushReplay` (`store.dart:478-506`), so P1c adds a `sessionHistoryLoadedProvider(sessionId)` over it. | `_historyLoaded` exists precisely because the cursor alone cannot tell a whole log from an auto-mirrored tail (`store.dart:400-411`), and #147 made `sub` ask for the whole history until the client actually holds it — so the *fact* is already tracked; only its visibility is missing. Without the gate the panel reports "3 turns" for a session that had forty. Review caught the first draft reading this as if it were already reachable from the widget layer. |
| **D17** | **A11y: a finished row's duration goes in its semantics label; a live counter is never a live region; and the 60 s escalation is carried by the semantics label as well as by colour.** The running spinner keeps its existing `semanticsLabel: 'running'`. | **And the 60 s escalation (D6) must be spoken, not only coloured**: past the threshold the label reads “running 1m 12s, taking longer than usual”. A per-second announcement makes the transcript unusable with a screen reader — the duration is only *news* when the span ends. Reading the number into the completed row's label is where it belongs, and the spinner already carries the running state. |
| **D18** | **The turn derivation is a separate pure pass — `deriveTurns(List<SessionEvent>)` → `List<TurnSpan>` — not new state threaded through `foldEvents`.** The receipt row is then projected into the chat items from that result; the session rollup (D11) reads the same result without touching chat items at all. | `foldEvents` already carries item construction plus three streaming identity maps plus in-place replacement (`chat_items.dart:303`). Adding turn intervals, gate accumulation, a degenerate-turn filter and a new row type into the same walk mixes two responsibilities and makes every turn test depend on incidental row ordering. As a separate pass, D10/D10a/D10b are testable as a table of event lists → spans with no widgets and no chat items in sight — which is what makes P1a's claim ("this is where the correctness risk lives") true rather than aspirational. It also stops the rollup depending on the transcript projection, since it needs turns and not rows. |
| **D19** | **An archived / read-only transcript renders every *finished* label — durations, receipts, the rollup — and starts no live counter.** | The finished numbers are the archive's whole value ("what did this branch cost me?"), and they are static text derived from timestamps, so they are correct with no clock at all. A live counter, by contrast, would tick against a session that cannot be running — and D6a already freezes a counter whose turn closed, which is exactly the archived case; this decision just names it so nobody wires the notifier to an archived pane. |
| **D20** | **Strings are hard-coded English with explicit singular forms** (`1 tool` / `14 tools`, `1 turn` / `18 turns`), matching every other string in the app. | The app has no `l10n` wiring today, so introducing `intl` for two plurals would be a subsystem smuggled in behind a duration label — the opposite of surgical. A hand-written singular is two lines and honest about the app's current scope. Recorded as a decision only because a reviewer would otherwise be right to ask. |

---

## Verified against the real adapters (not just the app)

D10 is the one decision the app cannot prove on its own — it asserts what the *server* puts in the
log. All five claims below were traced through `turn-status.ts`, `acp.ts`, `codex.ts`, `session.ts`
and `manager.ts` before this spec was locked; two of them changed the rule.

**Changed the rule:**

- **`exited` is not a turn transition.** `manager.ts:1421` records it on a *failed reattach*
  (`if (session.status !== "exited") session.recordStatus("exited")`), timestamped `Date.now()` at
  that moment. An agent that died mid-turn therefore gets its `exited` whenever the user next reopens
  the session — hours or days later. The first draft closed turns on `idle | exited` and would have
  printed a multi-day wall clock for a thirty-second turn. Only `idle` closes (D10).
- **A cancelled codex turn may never close, and that is now a specified outcome.** `cancel()` fires
  `turn/interrupt` and discards the result (`codex.ts:334-337`); the tracker closes only on a
  `turn/completed` notification, and the notification handler covers `turn/started` and
  `turn/completed` **only** — no `aborted`, no `failed` (`codex.ts:520-531`). So closure depends
  entirely on codex sending `turn/completed` after an interrupt. Either way D10 is now well-defined:
  it closes on the `idle` if one arrives, and emits no receipt if none does. ACP is unconditionally
  safe — `leaveTurn` runs in a `.finally` (`acp.ts:339-341`).

**Confirmed sound:**

- **`steered: true` is persisted, not just optimistic.** Both codex steer paths emit the echo through
  `emitEvent` → `record` with `{ ...turn.echo, steered: true }` (`codex.ts:315`, `:329`), so the flag
  survives a reload and D10's steer clause holds on replay. (ACP never steers — a busy message is
  queued and legitimately opens its own turn.) Had this been echo-only, every steer would have
  produced a phantom receipt after any reconnect.
- **One `idle` brackets nested turns, so "first `idle` after the open" cannot close early.**
  `TurnStatusTracker` holds a `Set` and `settleIdle` emits only when it empties, so an inner
  `turn/completed` while another turn is still live emits nothing (`turn-status.ts`,
  `codex.ts:526-529`). Repeated `running` events are harmless — the turn is already open.
- **A single seq-ordered walk is sufficient, and no status is ever missing from the log.** Everything
  goes through `record()` on one monotonic seq (`session.ts:270-276`), and `session.status` is not in
  `NO_FANOUT_KINDS` — that set is the three delta kinds plus `session.usage` (`session.ts:29-34`),
  and `isNoFanout` suppresses only the session-list `metaChanged` broadcast, never persistence.
- **A leading bare `idle` is harmless.** Both adapters emit `idle` at spawn/resume with no preceding
  user message (`codex.ts:222`, `acp.ts:272`); an `idle` with no open turn closes nothing.

## Review findings applied (rev 2)

The spec was reviewed once for the turn derivation (results folded into D10/D10a above), then by two
parallel `codex exec` jobs — one on technical correctness, one on SE practice — logged under
`.piano/codex-jobs/20260809-144202-spec47-{technical,practice}/`, and finally by `ocr review` on the
mockup. Every finding below was re-checked against the source (or re-run) by the controller before
being accepted or rejected.

**Accepted — these changed the spec:**

| Finding | Change |
| --- | --- |
| The per-turn **cost** token is not derivable: `reduceEvent` returns for `session.usage` *before* appending to `events` (`store.dart:249-258`), so the fold never sees a usage snapshot — and codex prices nothing anyway (`codex-map.ts:84`). | **D9a** — cost cut from the receipt. |
| **D5's "1 Hz" was factually wrong**: `PulseClock` notifies at 20 Hz (`pulse.dart:13`) and `PulseBuilder` rebuilds on every notification (`pulse.dart:95-128`); `period` throttles nothing. | **D5** rewritten around a derived second-cadence notifier, which doubles as the test seam. |
| `endedTs == null` ≠ "still running": codex's `endTurn()` only clears bookkeeping (`codex-map.ts:111-114`) where ACP synthesises closes (`acp-map.ts:196-207`), so a card can have no end forever. | **D1** null semantics restated; **D6a** freezes the counter at the enclosing turn's close. |
| `_historyLoaded` is private controller state (`store.dart:400-416`), not reachable from the widget layer as D16 assumed. | **D16** now specifies `sessionHistoryLoadedProvider`. |
| The app model has no `createdAt` at all — the first draft specified only the server DTO. | **D12** covers both halves, and requires nullable rather than `0`-as-unknown. |
| Turn state inside `foldEvents` would mix responsibilities and couple turn tests to row order. | **D18** — `deriveTurns` as a separate pure pass. |
| Unspecified: invalid/negative spans, archived transcripts, plurals, live-label width jitter. | **D10b**, **D19**, **D20**, **D6b**. |
| **On-device run** (sixth pass, real macOS on Impeller + real iOS simulator with seeded data, light and dark): the app already prints `18:03` under every message bubble; tool rows truncate on a real 402 pt screen in both modes; the app follows system appearance, and the audit's dark-only numbers are worse in light (`ThinkingLine` 2.76:1 vs 3.57:1). | **D22** (the two time vocabularies), Non-goals narrowed, **D9b** extended to name the light-mode ratio. |
| **Golden-render audit** (fifth pass, real widgets via `app/test/sim/transcript_timings_sim_test.dart`): the "invented" dim grey is what the app itself ships (`alpha: 0.65` → `#6f6f6f`, 3.57:1) and the shimmer trough measures 1.34:1 — both **pre-existing**; D2's width rationale is false at 720 pt (≈600 px sits empty) and understated at 393 pt (two of four rows already truncate); the expanded body has labelled sections, not flat text. | **D9b** corrected (pre-existing, plus a full-opacity rule for the new label), **D2** rationale narrowed to the noise argument, **D2a** (phone rendering is a verification requirement), **D3a** (facts line matches the existing body grammar). |
| **Design review** (fourth pass, on the rendered board at 390/768/1440): the invented "dim" grey measures 3.57:1 (AA needs 4.5); `prefers-reduced-motion` was ignored entirely; the 60 s escalation was colour-only; the receipt overflows a 390 pt row once gated; the 11.5 px label is off the app's type scale. | **D9b** (named token, quiet by size), **D21** (reduced-motion cadence), **D17**/**D6** (escalation spoken), **D9c** (mobile stack), **D6c** (`bodySmall`). |
| **`ocr review`** (third pass, on the mockup — the only file it supports): the reference `fmt()` rounded *inside* each tier, so `59.5s → "60s"` and `119.7s → "1m 60s"`. Verified, and two further cases found: the carry **cascades a tier** (`3599.7s → "59m 60s"`) and a non-finite input printed `"NaNd NaNh"`. | **D13** now mandates round-once-then-integer and a `String?` return; **D13a** pins the carry cases as required tests, because the documented ladder passes without them. Mockup JS fixed so the reference implementation cannot be ported as-is. |

**Rejected — and why:**

- **"Cut D9 (the whole receipt); the facts already exist in the rows and the usage panel."** They do not:
  a turn's wall clock is not recoverable from the rows, because the gaps *between* tool calls are model
  latency that no row represents — and the transcript has no turn boundaries at all today. The user
  chose this variant (board §4B) over the alternatives with the cost of a new row type visible. Cost
  *was* cut (D9a), which is the part of the objection that held.
- **"Cut D3 (the expanded-body facts line); `started 14:02:14` is unrequested."** Kept — it is what makes
  D2's threshold safe. Gating the collapsed label means "fast" and "not measured" look alike, so the
  unabbreviated figure must be unconditionally reachable. It is also the reason no row needs an
  absolute-timestamp column.
- **"Cut D10a; let the error row speak for a failed turn."** Kept: the problem is the *contradiction* —
  an error row and a success receipt describing the same turn is worse than either alone.
- **"Cut D11's `Median turn` as speculative analytics."** Kept, one line, and it is the only row that
  answers "is this getting slower"; `Turns` and `Agent time` alone cannot. Flagged as the first thing
  to drop if P1c runs long.
- **"Raise the mobile threshold from 2 s to 10 s — a phone row is scanned, not audited."** Not taken, but
  recorded because the evidence is real: at 390 pt the trailing token visibly costs the summary about four
  characters (`read app/lib/store/ch…` against `…chat_it…` on the gated variant). A *per-viewport* threshold is
  a second rule for one decision, and the user chose §1B's single 2 s gate with that cost visible. Revisit only
  if the shipped phone transcript proves the path unreadable — see Non-goals.
- **"Cut D4's three renderings."** The other reviewer independently defended it as one accessibility
  contract (SPEC-41's rule), which is the right read.

## Phasing

- **P1a — the pure layer, no UI.** Five tasks, each red-first:
  1. `formatElapsed` — table test over every ladder boundary, rounding, zero-padding, plus the
     **carry cases D13a names by value** (`59.5s`, `59.9s`, `119.7s`, `3599.7s`, `9.96s`) and the
     unrepresentable ones (negative, non-finite → `null`). The carry cases are mandatory, not
     illustrative: the documented ladder alone passes under the buggy algorithm.
  2. `endedTs` / `lastTs` survive the fold's in-place replacement (D1) — including a streamed
     thinking card whose `lastTs` advances per delta.
  3. `deriveTurns` (D18) — table test over hand-built streams: ordinary, steered, gated, leading bare
     `idle`, nested `running` pairs, a late `exited` (**asserts no receipt, not a three-day one**),
     unclosed, and the `turn/start`-failure bracket (D10/D10a).
  4. The rollup arithmetic (D11) — wall/gated/agent totals, median, and the incomplete-history gate.
  5. The second-cadence notifier and server-clock offset (D5/D15) — driven by a fake clock, asserting
     that the offset never advances from a replayed event.

  All of it is pure functions over event lists plus one store field. **This phase is where the
  correctness risk lives**, and D18 is what keeps that true — none of these five tests builds a widget.
- **P1b — the transcript.** D2/D3/D4 (finished tool rows + facts line + tooltip), D6/D6a/D6b (running
  row counter, its 60 s escalation, the freeze and the width reservation), D7 (thinking), D8 (working
  indicator), D9 + D10a (receipt row and the degenerate-turn suppression), D19 (archived panes),
  D20 (plurals), D17's labels. Both surfaces — mobile `SessionScreen` and `DesktopChatPane` share
  every one of these widgets, so there is no per-surface work here.
- **P1c — session rollup.** D12 (both halves of `createdAt`), D16 (`sessionHistoryLoadedProvider`),
  D11 (four popover rows). Ordered last because `Agent time` sums P1a's turn spans.
- **P2 — follow-ups, explicitly out of P1.** Enriching the "finished its turn" notification with the
  duration (UX.md §7 already promises *"Tests passed (42/42) in 2m13s"*, and `notificationFor` takes
  no duration today); a duration column in the archived-sessions view.

## Verification

Unit tests carry D1/D10/D10a/D13/D14 (pure), widget tests carry D2/D6/D7/D9 (threshold boundaries at
1999/2000 ms, escalation at 59/60 s, a steered message emitting no receipt, a gated turn's caution
token). The turn derivation gets a table-driven test over hand-built event lists covering every case
the adapter review turned up: a bare leading `idle`, an `exited` arriving days after a dead turn
(**asserts no receipt, not a three-day one**), nested `turn/started` pairs closing on one `idle`, a
`turn/start` failure bracket (no receipt, D10a), and a cancel that never settles.

Two things unit tests structurally cannot prove, so both are checked against a real running session
on the keyless stub loop (`docs/DEVELOPMENT.md`):

1. **The turn derivation against real adapter output** — that a real `pi`/`codex` turn with an
   approval gate produces exactly one receipt whose wall clock matches the wall clock, that a steered
   message does not split it, and **what codex actually emits after `turn/interrupt`** (the review
   could not settle this from the source: the interrupt result is discarded and no
   `aborted`/`failed` notification is handled, so whether a cancelled turn ever closes is an
   empirical question). The stub adapter neither gates nor interrupts, so this needs a real harness.
2. **The rendered result at both widths**, by re-running the golden audit
   (`PORTS_AUDIT=1 flutter test --no-pub --update-goldens test/sim/transcript_timings_sim_test.dart`) and comparing
   against the committed "before" images. This is what caught D2's false premise and D9b's misdiagnosis; a duration
   label is exactly the kind of change whose cost is only visible rendered.
3. **That the 1 Hz clock does not regress streaming.** `app/tool/perf/stream_bench.dart` exists and
   is the baseline; a live counter on the tail row during a long stream must not move it.

## Non-goals

- **Progress bars or ETAs on a running tool call.** No denominator exists — the same argument that
  makes `ContextUsageRing` refuse to render without a known window.
- **An absolute-timestamp column on tool rows.** Answers "when", not "how long". Note this is narrower than
  the first draft claimed: an on-device run showed **the transcript already prints a clock time (`18:03`) under
  every message bubble**, so the app is not timestamp-free — it simply does not timestamp *tool* rows, and adding
  a second time column there is what this rejects. See D22 for the reconciliation.
- **Colour-graded durations.** Only D6's "past 60 s on a running call" is a genuine *status*; a
  green/amber/red gradient across every row spends the whole colour budget on a secondary fact.
- **Sparklines or trend graphs inline.** Trend is D11's `Median turn`; graphs belong to the
  performance dashboard (SPEC-37).
- **Consolidating `formatDuration` / `portUptimeLabel`** (D13) — a deliberate non-goal, not an
  oversight.
- **A per-viewport duration threshold** (a higher gate on the phone than on the desktop) — deferred, **but the
  evidence for it hardened after the golden audit** (see D2a): at 393 pt two of four real rows already ellipsize
  with no duration present. If the phone transcript proves unreadable in P1b, this is the first thing to revisit.
- **Per-tool aggregate stats** ("you spent 4m in `bash` this session"). A different feature with a
  different home.
