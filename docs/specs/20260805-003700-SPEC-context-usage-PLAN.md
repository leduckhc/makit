# SPEC-context-usage (context usage) — Amendment plan: correct usage, and the extension's own repo

Spec: [`20260805-003700-SPEC-context-usage.md`](./20260805-003700-SPEC-context-usage.md)
Mockup: [`../../mockups/context-usage.html`](../../mockups/context-usage.html) (amended)

Ground rules (AGENTS.md): failing test first, SOLID/YAGNI, surgical diffs.
Branch point: `d34c48b`, server 927 tests green.

This is not the original build plan — SPEC-context-usage shipped in `fe9659b`. It is the plan for the
amendment that followed the first real long session, where the panel read `$0.20` while pi's
own `/sessions` read `$22.16`.

## Status

| Task | State |
|---|---|
| T1 cumulative cost instead of the last message's | ✅ done — `6ba658a`, 6 tests |
| T2 send the per-category `totals` breakdown pi never sent | ✅ done — `6ba658a`, part of the same tests |
| T3 derive totals from session entries (fixes resume, fork, compaction) | ✅ done — `6ba658a` amended → `a467c74` lineage, 4 tests |
| T4 move the hook `message_end` → `turn_end` | ✅ done — found by real-pi verification, not by unit tests |
| T5 extract the extension to its own repo, installed as a pi package | ✅ done — `a467c74` + `makit-pi-usage@v0.1.0` |
| T6 docs sweep: spec, specs README, mockup | ✅ done — this file, and the amendment note on the mockup |
| T7 composer footer overflow | ⛔ **not done** — pre-existing, deliberately out of scope (below) |

**Complete** apart from T7. server: 904 tests + `pnpm typecheck` clean (the 23 extension tests
moved to the new repo's CI). app: `flutter analyze` clean, usage tests pass. `ocr review`: 0
findings on the final diff.

## The bug in one line

`SessionUsageDTO.cost` and `.totals` are documented as **cumulative for the session**; the
extension was forwarding `event.message.usage.cost.total`, which is the cost of **one
assistant message**, and was sending no `totals` at all — so pi sessions also fell through to
the panel's "no token breakdown" footnote while the breakdown rows sat unused.

## T1 + T2 — cumulative cost and a real breakdown

`makit-pi-usage`'s `usage.ts` / `usage.test.ts` (then `.pi/extensions/pi-usage/`).

- RED: `addUsage` does not exist; a test that folds two messages' usage and expects
  `cost 0.5` / `total 3038` fails to import.
- GREEN: a pure accumulator over pi's per-message categories, and `buildUsage` emits
  `totals` + the accumulated `cost`.
- Two mappings, each a bug if skipped:
  - `total = input + output + cacheRead + cacheWrite` — pi's own `/sessions` arithmetic
    (`AgentSession.getSessionStats`), so the two agree to the token. `reasoning` is excluded
    because pi documents it as a subset of `output`.
  - the reported `input` is pi's `input + cacheRead + cacheWrite`. makit follows codex in
    nesting cached input **inside** input, because the panel's cache bar is
    `cachedInput / input`; pi reports the three disjointly, so passing its figure through
    nests a 33M cache row under a 360-token parent. Test: `cachedInput <= input`, always.
- Verify: 6 new tests; `isWorthSending` also had to compare `totals`, or a turn that changed
  only the breakdown would be suppressed.

## T3 — derive from the session entries, don't accumulate

- RED: `sumUsage` does not exist. Two tests describe what an accumulator cannot do: a
  **resumed** session whose earlier turns belong to a process this one never ran, and a
  `compaction` entry whose usage never arrives as an assistant message.
- GREEN: `sumUsage(ctx.sessionManager.getEntries())`, reproducing `getSessionStats` exactly —
  assistant messages, billed tool results, `compaction`/`branch_summary` entries, including
  history since compacted away, because it was still billed.
- Why derived beats seed-plus-increment (the alternative considered and rejected): an
  incremental counter needs a seed path *and* an increment path that must agree forever, and
  re-seeding on every history transition (`session_start` × 5 reasons, fork, `navigateTree`,
  compaction). A missed hook makes a monotonic counter drift silently and it never
  self-corrects. Deriving is a pure function of session state, so it self-heals.
- Cost of deriving, measured rather than assumed: **0.53 ms** per turn on the largest real
  session on this machine (4,568 entries / 11 MB), 0.06 ms at 400 entries, 6 ms at 50k. It
  scales with entry **count**, not file size — only `usage` fields are touched, never message
  content — and does no I/O, because `getEntries()` is the array pi already holds. Parsing the
  11 MB file ourselves, even once per resume, would cost more than every scan a session will
  ever do.
- Entries come from a user-editable JSONL, so non-finite values are dropped rather than
  coerced, and an unmeasured category stays absent rather than becoming a real `0`.

## T4 — `turn_end`, not `message_end`

Found only by driving real pi; every unit test passed either way.

At `message_end` the message is **not yet in the session** — handlers are allowed to rewrite
it, including its `usage` — so entry-derived totals lag a turn. Observed against real pi:

```text
{"contextTokens":18377,...}                        ← turn 1: no totals at all
{"totals":{"total":18377},"cost":0.11492875}       ← resumed process: missing its own turn
```

`turn_end` fires after the entries land, and once per turn rather than per message.

## T5 — extraction

New repo `github.com/leduckhc/makit-pi-usage` (`v0.1.0`, public, CI green), created with
`git subtree split --prefix=.pi/extensions/pi-usage` so both commits that shaped the code keep
their history. makit declares it in `.pi/settings.json`:

```json
{ "packages": ["git:github.com/leduckhc/makit-pi-usage@v0.1.0"] }
```

pi installs project packages automatically once the project is trusted.

The motivation is a failure, not tidiness: the previous install instruction was
`ln -s "$PWD/.pi/extensions/pi-usage" ~/.pi/agent/extensions/pi-usage`. That link pointed into
a git worktree; when the worktree was pruned after merging, the link dangled and pi silently
loaded **nothing** — every pi session showed no usage, with no error anywhere.

Carried over rather than re-invented: makit's pnpm posture (`strictDepBuilds` with an
allow-list, 3-day release-age cooldown, `blockExoticSubdeps`, `trustPolicy: no-downgrade`).
Both of makit's documented exceptions reproduced themselves immediately — `tsx` pinned to
4.23.1 because 4.23.6 is inside the cooldown, and the same `undici-types@6.21.0` provenance
exclusion. The extension also stopped borrowing `@types/node` from `server/node_modules`
through a `typeRoots` hack, which was the one thing keeping it from standing alone.

Couplings removed from makit are build-time only: the server's `typecheck` no longer compiles
the extension and its test glob no longer collects the extension's tests (923 → 904 here, 23
of them now in the new repo's CI). The bridge contract (`POST /usage`, `MAKIT_BRIDGE_*`) is
untouched, so nothing about the runtime path changed.

## T7 — the composer footer (still open)

SPEC-context-usage recorded the pill row as "pre-existing and untouched". Re-measured in the running app:

- There is **no** `RenderFlex` overflow — the `Flexible` wrappers prevent it.
- With a longer model name the row wants **500 pt** of natural width (model 225.5 + thinking 88
  + mode 150.5 + ring 36) against a **267 pt** budget, so every label is squeezed to
  **21.8 pt** — one glyph plus an ellipsis (`C…`, `h…`, `A…`).
- Horizontal scrolling would keep labels legible but push the ring ~250 pt off-screen, which
  breaks the one thing the ring is for.
- The right fix is the SPEC-model-picker-menu-per-model-config shape: fold the legacy `model`/`thinking`/`mode` trio into one
  pill that opens a sheet, exactly as `ModelConfigFooter` already does for agents that send
  `configOptions`. The overflowing path is the legacy one, i.e. pi.

That is a mobile-footer redesign across both surfaces plus goldens, so it wants its own spec.

## Verified against the real binaries

Unit tests cannot show that any of this leaves the process, so each hop was driven directly.

| Hop | Result |
| --- | --- |
| real `pi` → `pi-usage` → HTTP sink, one process | turn 1 `total 18377` / `$0.0092955` |
| same session file, **second** process (`--session-id`) | `total 36766` / `$0.018597` — inherited |
| same file, **third** process via `pi --session <path>` (the form `pi-acp` uses on `session/load`, i.e. how a makit resume reaches pi) | `total 55167` / `$0.028491`, `cachedInput 55047` of `input 55155`, while `contextTokens` stayed `18401` |
| independent sum of that session's JSONL | `total 55167`, `cost 0.028491` — byte-identical |
| `pi -e <dir>` / `pi -e git:…@v0.1.0` / `pi install` then plain `pi` | posts a snapshot in all three, with the old symlink deleted |

## Not verified

The iOS simulator loop (`tool/e2e.sh --mode=stub`) still fails before any of this code runs —
`launchMakit` times out waiting for a `new session` tile the repo-centric home no longer
renders — and fails identically on a clean tree. Pre-existing; untouched. Unchanged from the
original SPEC-context-usage plan.
