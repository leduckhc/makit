# SPEC-37 — Context usage: tokens vs limit, per session

**Status:** Implemented · **Priority:** P3 · **Branch:** `feat-context-usage`
**Depends on:** SPEC-26 (composer footer selectors), SPEC-32 (budget-panel precedent), SPEC-36 (pi-extension + bridge precedent)

**Scope:**
*protocol:* `server/src/protocol.ts` (new `session.usage` event kind + `SessionUsageDTO`),
`server/src/protocol/codec.ts` (`EVENT_KINDS`).
*server:* `server/src/adapters/codex-map.ts`, `server/src/adapters/acp-map.ts`,
`server/src/session.ts` (no-fanout kind), `server/src/bridge.ts` (new `POST /usage`),
`server/src/manager.ts` (bridge → session event).
*pi:* `.pi/extensions/pi-usage/` (new, self-contained, mirrors `pi-computer-use/`).
*app:* `app/lib/transport/protocol.dart`, `app/lib/store/models.dart`,
`app/lib/store/store.dart`, `app/lib/store/chat_items.dart` (exhaustive switch),
`app/lib/ui/composer/context_usage.dart` (new — ring + details panel), mounted in
`app/lib/ui/session/session_screen.dart` and `app/lib/desktop/chat/desktop_chat_pane.dart`.

---

## Goal

Show, per session, **how much of the model's context window is in use, and what it is
costing** — the numbers pi prints in its own footer, surfaced on the phone and the desktop
chat pane where makit currently shows nothing at all.

## What the agents actually report (verified, not assumed)

This is the whole design constraint, so it is recorded here as ground truth. Verified on
2026-08-05 against the installed binaries, not from docs.

| Source | Event | Payload | Cost? |
| --- | --- | --- | --- |
| **codex app-server** | `thread/tokenUsage/updated` | `{threadId, turnId, tokenUsage: {total: Breakdown, last: Breakdown, modelContextWindow}}` where `Breakdown = {totalTokens, inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens}` | no |
| **ACP v1** | `session/update` → `usage_update` | `{used, size, cost?: {amount, currency}}` | yes |
| **pi** (via extension) | n/a — `ctx.getContextUsage()` + `ctx.sessionManager.getEntries()` | `{tokens, contextWindow, percent}` for context; per-entry `usage` (`input`/`output`/`cacheRead`/`cacheWrite`/`reasoning`/`cost`) for billing | yes |

Codex types are generated ground truth: `codex app-server generate-ts --out DIR`.
ACP's shape is `$defs.UsageUpdate` in `acp-docs/schema/v1/schema.json`.

### Two findings that shape the implementation

**1. `total` is billing; `last` is context.** A raw stdio spike over two turns:

| | turn 1 | turn 2 |
| --- | --- | --- |
| `total.totalTokens` | 19,492 | 39,000 |
| `last.totalTokens` | 19,492 | 19,508 |
| `last.cachedInputTokens` | 0 | 19,200 |
| `modelContextWindow` | 258,400 | 258,400 |

`total` accumulates across turns and must **never** be drawn against the context window —
it would read 15% full when the context is 7.5% full, and would cross 100% on a long
session that never came close to compaction. Context occupancy is `last.totalTokens`,
because the last request's `inputTokens` already contains the entire conversation plus the
system prompt and tool definitions. The notification arrives **once per turn**, at turn
completion — low enough frequency to persist as an ordinary session event.

**2. pi-acp emits no `usage_update`.** Enumerating every `sessionUpdate` literal in the
shipped `pi-acp/dist/index.js` yields only: `agent_message_chunk`, `agent_thought_chunk`,
`available_commands_update`, `config_option_update`, `current_mode_update`,
`session_info_update`, `tool_call`, `tool_call_update`, `user_message_chunk`. So the ACP
handler alone would leave **pi — the primary agent — permanently blank**. Hence the pi
extension, which is also the only source that yields a real cost figure for pi.

The ACP handler is still written: it is three lines, it is the spec-correct behaviour, and
other ACP agents (including future pi-acp versions) may emit it.

## Non-goal: the per-category breakdown

The original ask was to break down *what* is eating the context — system prompt, tool
definitions, skill descriptions, MCP definitions, messages, subagents. **No agent protocol
reports this.** All three sources are aggregate-only. Attributing tokens to categories
would require makit to re-tokenize with its own estimator and to guess at the parts it
cannot see (the agent's system prompt and built-in tool schemas), producing numbers that
disagree with the provider's. Out of scope; deliberately not estimated.

One exact substitute is available for free and worth noting for a follow-up: the **first**
turn's `last.inputTokens` on a fresh session is the fixed baseline — system prompt + tool
definitions + `AGENTS.md`, with no conversation in it yet. Measured 19,487 tokens for the
codex default model. Not implemented here.

## Normalized event

Each source fills a different subset, so every field is optional except `measuredAt`.

```ts
export interface SessionUsageDTO {
  /** Tokens currently occupying the context window. */
  contextTokens?: number;
  /** Context window size in tokens. */
  contextWindow?: number;
  /** Cumulative session totals — billing, NOT context occupancy. */
  totals?: {
    total?: number; input?: number; cachedInput?: number;
    cacheWrite?: number; output?: number; reasoning?: number;
  };
  /** Cumulative session cost. */
  cost?: { amount: number; currency: string };
  /** Epoch ms. */
  measuredAt: number;
}
```

Mapping:

| Field | codex | ACP | pi extension |
| --- | --- | --- | --- |
| `contextTokens` | `last.totalTokens` | `used` | `getContextUsage().tokens` |
| `contextWindow` | `modelContextWindow` | `size` | `getContextUsage().contextWindow` |
| `totals` | `total` | — | session entries summed (`input` = pi's `input + cacheRead + cacheWrite`, since makit nests cached input inside input) |
| `cost` | — | `cost` | session entries' `usage.cost.total` summed |

**Unmeasured is not zero.** A missing field renders as absent, never as `0` — the same rule
`BudgetBucket` already enforces for GitHub buckets (`models.dart`), for the same reason: a
zeroed bar and an unknown bar mean opposite things.

## Delivery

`session.usage` is an ordinary session event, appended and replayed like `session.meta`,
with latest-wins in the reducer. It joins `session.ts`'s no-fanout set so a usage update
does not re-broadcast the sessions snapshot (SPEC-17 P2) — usage changes nothing in the
session list DTO.

The pi extension posts to a new `POST /usage` route on the existing loopback bridge
(`bridge.ts`, today `/uicall`-only), authenticated with the same bearer token and
addressed by `sessionId`; the manager turns it into the same `session.usage` event.

### Billing totals are derived, not accumulated

The extension sums `ctx.sessionManager.getEntries()` on every turn, reproducing
`AgentSession.getSessionStats()` exactly: every assistant message, every billed
tool result, and every compaction/branch summary — including history since
compacted away, because it was still billed. An in-process accumulator was tried
first and is wrong in two ways a long-lived session hits immediately: a **resumed**
session's earlier turns belong to a process this one never saw (a $22 session
reported as new), and a compaction's own tokens never arrive as an assistant
message at all.

It hooks **`turn_end`, not `message_end`**. At `message_end` the message is not in
the session yet — handlers are allowed to rewrite it first — so the derived totals
lag a turn: verified against real pi, the first turn posted no totals at all and a
resumed process reported turn 1 while omitting turn 2. `turn_end` fires after the
entries land, and once per turn rather than per message.

pi's `input` **excludes** cache reads/writes, while makit (following codex) treats
cached input as a subset of input — the panel's cache bar is `cachedInput / input`.
So the extension reports `input + cacheRead + cacheWrite` as `input`; passing pi's
figure through drew a 33M cache row nested under a 360-token parent. `total` is
`input + output + cacheRead + cacheWrite`, the same arithmetic `/sessions` prints,
so the two agree to the token.

### The extension needs a manual install

makit cannot inject it. `SpawnOpts.extensions` is never forwarded by `AcpAdapter`,
because `pi-acp` spawns `pi --mode rpc` itself and gives makit no `-e` channel —
the same constraint SPEC-36 hit. Environment variables *do* propagate
(`spec.env` → pi-acp → pi), which is why the bridge coordinates arrive. So, once:

```sh
ln -s "$PWD/.pi/extensions/pi-usage" ~/.pi/agent/extensions/pi-usage
```

Until that link exists, pi sessions show no usage. The extension is inert outside
makit (no `MAKIT_BRIDGE_*` → it registers nothing), so the link is safe to leave.

## App surface

`state.usage: Map<String, SessionUsage>` + `sessionUsageProvider` family, mirroring
`state.meta` / `sessionMetaProvider` exactly.

A **circular gauge in the composer footer that opens a details panel on tap**
(`ContextUsageButton`). The footer already hosts per-session model/thinking/mode state on
both surfaces, so usage belongs there rather than in a new chrome slot — and the ring is a
32 pt tap target with no label, because the row is tight (see below). Presentation follows
`ComposerConfigOptions`: a `MenuAnchor` popover on desktop, a modal bottom sheet on mobile,
both wrapping the same host-agnostic `ContextUsageDetails`.

### Why a ring and not a label

Measured on a 375 pt phone: the footer's pill area is **267 pt**, and a 3-config-pill pi
session already needs **279 pt** — it overflows *before* usage is added. A full-detail pill
(`8% · 19.4k/258k · $0.42`) measures **166 pt** and ellipsized its own numbers; a
percent-only pill is 57 pt; a bare bar 37 pt but illegible at 3%. The ring costs **32 pt**,
the least of any in-row control, and moves the numbers somewhere they have room.

The pill row's overflow is **pre-existing and untouched** — no in-row control fits a 3-pill
session, including none at all. Flagged, not fixed.

### The panel

Context reading (big ring + percentage + used-of-window + headroom) → cumulative session
totals (input, cache share, output, reasoning) → cost → a footnote. The two token figures sit
in separate blocks with the distinction spelled out, because they are trivially conflated and
mean opposite things: codex's cumulative total hit 39k after two turns while the context held
19.5k.

Ring semantics: arc from twelve o'clock, neutral ink → `kStatusWarning` at ≥70% →
`colorScheme.error` at ≥90% (the sanctioned status hues — **not** `colorScheme.tertiary`,
which DESIGN.md §Colors forbids).

**There is no unmeasured rendering.** A ring means "this share of a whole", so without a
known window there is no whole and the control is absent entirely — `ContextUsageRing.fraction`
is non-nullable to make that unrepresentable. This covers more states than it first appears:
before the first turn, any pi session without the `pi-usage` extension, an ACP agent reporting
`used` with no `size`, and pi immediately after a compaction (it keeps reporting the window but
nulls the count until the next reply, where a 0% ring would misread as "context emptied").
An earlier draft drew a dotted track for these; the goldens showed it was not reliably
distinguishable from a real 3% reading at 18 px, and the two mean opposite things.

Accepted limitation: at 3% the arc is a short tick, so the ring cannot be read as a precise
number. That is the point of the click — the ring answers "is my context filling up?", the
panel answers "by how much?".

## Tests

| Layer | Test |
| --- | --- |
| `codex-map.test.ts` | `thread/tokenUsage/updated` → one `session.usage`; `contextTokens` is `last.totalTokens`, **not** `total.totalTokens`; null `modelContextWindow` omits `contextWindow` |
| `acp-map.test.ts` | `usage_update` → `session.usage` with `used`/`size`/`cost`; absent `cost` omits the field |
| `contract.test.ts` + `codec_contract_test.dart` | a `session.usage` entry in the byte-identical `events.json` golden fixture round-trips in **both** languages |
| `bridge.test.ts` | `POST /usage` requires the bearer; a body with no readings is a 400; non-numeric fields are dropped, not coerced |
| `.pi/extensions/pi-usage/usage.test.ts` | env gate needs all three vars; null readings omit rather than zero; a real `0.00` cost is kept; unchanged repeats are suppressed; `sumUsage` counts exactly the entries `/sessions` counts (assistant, billed tool results, compaction/branch summaries) and drops non-numeric junk; a **resumed** session's inherited spend is in its first report; cached input never exceeds input |
| `session_usage_test.dart` | `fromJson` omits missing fields rather than zeroing them; `fraction` is null on an unmeasured half and clamps past 1.0; reducer is latest-wins and per-session |
| `context_usage_test.dart` | `percentLabel`/`headroomLabel`/`cacheShare` return null rather than inventing a denominator; no ring until measured; the numbers are absent from the footer and present after a tap; the panel separates session total from context, and omits cost when unpriced |
| `context_usage_golden_test.dart` | the ring ladder at the real 18 px (what a 3% arc actually looks like) plus the three panel shapes |
| `integration_test/stub/context_usage_test.dart` | full-stack: no ring before the first turn; after it, tapping the ring shows `8%` / `20.2k of 258k tokens` / `$0.02` |

`StubAdapter` emits a deterministic per-turn usage ramp so the e2e loops exercise
the real path rather than rendering an indicator nothing feeds, and
`test/e2e-server.ts` wires `onUsage` for parity with `serve.ts`.

## Verified against the real binaries

Unit tests cannot show that any of this leaves the server, so each hop was proven
separately:

| Hop | Result |
| --- | --- |
| real `codex app-server` → `CodexAppServerAdapter` | one `session.usage`: `19440` of `258400`, totals + cache present, no cost |
| `StubAdapter` → session → **WSS client** | `20200` of `258400`, cost `$0.021`, arriving as `session.event`/`session.usage` |
| real `pi` (via `pi-acp`) → `pi-usage` → `POST /usage` → session → **WSS client** | `29408` of `1000000`, cost `$0.1838725` |
| real `pi` → `pi-usage` (`-e`, bridge env, HTTP sink), **two separate processes on one session file** | turn 1 posts `total` `18377` / `$0.0093`; the RESUMED process posts `total` `36766` / `$0.018597` / `cachedInput` `36754` inside `input` `36758` — byte-identical to summing the session JSONL the way `/sessions` does |

**Not verified:** the iOS simulator loop (`tool/e2e.sh --mode=stub`). It fails on
this branch *before* any of this code runs — `launchMakit` times out waiting for a
`new session` tile that the repo-centric home no longer renders — and it fails
identically on a clean tree. Pre-existing; not touched here. The new integration
case is registered and will run once that harness is repaired.
