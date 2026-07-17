# SPEC-15 — Server adapter layer consolidation (transport, base, interaction, types)

**Status:** Proposed · **Priority:** P1 · **Source:** `docs/research/2026-07-16-code-quality-audit.md` §1 S1–S3, §3 T2
**Scope:** `server/src/adapters/**` only. Behavior-preserving restructuring.

---

## 🚦 Branch & worktree gate (NO GO if not met)

This spec **MUST** be implemented in a **new git worktree branched from `chore/code-quality-review`**, and its **pull request MUST target `chore/code-quality-review`** (not `main`).

- Base branch: `chore/code-quality-review`
- PR target branch: `chore/code-quality-review`

If either condition is not satisfied, **this spec is NO GO**.

```bash
git fetch origin chore/code-quality-review
git worktree add ../spec-15-adapters -b spec-15/adapter-consolidation origin/chore/code-quality-review
```

---

## Goal

The three real adapters (`pi.ts`, `acp.ts`, `codex.ts`) independently reimplement
the same transport, lifecycle, and interaction logic. Collapse the duplication
into shared modules without changing observable behavior. Target: ~250 lines
removed and a symmetric `Adapter + Mapper` shape across all three agents.

## Work items

### S1 — Extract one subprocess line-transport (~120 lines duplicated)

- **Where:** `adapters/pi.ts:159-260` (`ensureProcess`), `adapters/acp.ts:420-475`
  (`defaultConnect`), `adapters/codex.ts:370-455` (`defaultConnect`).
- **Duplicated:** piped-stdio spawn, prefixed stderr forwarding, the verbatim
  "settle-once, buffer exit code until `onExit` registers" dance, the
  copy-pasted swallow-`'error'` comment (×3), and an LF-only line splitter
  (`bindLfLines` in pi.ts, re-inlined in codex.ts).
- **Fix:** new `adapters/child_transport.ts` exporting
  `spawnLineProcess({ command, args, cwd, env, label }): { send, onLine, onExit, dispose }`.
  `CodexTransport`/`AcpTransport` become type aliases; each `defaultConnect`
  shrinks to ~3 lines; `PiAdapter.ensureProcess` keeps only pi-specific arg
  building + boot commands. Preserves the "a bad agent must never kill the
  daemon; stdout is LF-delimited JSON" invariant in **one** place.

### S2 — Introduce `SubprocessAdapter` base + `TurnStatusTracker`

- **Where:** `adapters/acp.ts:88-92,155-175,232-260`,
  `adapters/codex.ts:60-66,150-175,310-330`.
- **Duplicated:** the "turns-in-flight + pending-approvals → running/idle" state
  machine, hand-rolled twice with slightly different wording (drift that causes
  agent-specific "stuck spinner" bugs), plus `emitEvent`/`handleExit`/`exited`.
- **Fix:** `abstract class SubprocessAdapter extends EventEmitter implements AgentAdapter`
  owning `emitEvent`, `handleExit`, the `exited` flag, and a shared
  `TurnStatusTracker` (enter/leave turn + approval → emits `status`/
  `session.status`). `PiAdapter`, `AcpAdapter`, `CodexAppServerAdapter` subclass
  it. Give pi a `pi-map.ts` mirroring `acp-map.ts`/`codex-map.ts` so all three
  agents share the identical `Adapter + Mapper` shape (this is why `pi.ts` is
  ~200 lines larger). Fold the duplicated bottom-of-file first-line/title
  extractor into one shared helper.

### S3 — Unify elicitation/permission → UICall policy

- **Where:** `adapters/acp.ts:295-360`, `adapters/codex.ts:255-300`, plus
  `describePermission` / `describeCommand`.
- **Duplicated:** both `handleElicitation` encode the same
  "url→confirm / single-field→input / multi→decline" policy, differing only in
  response shape — already drifting.
- **Fix:** one pure `mapElicitation(params, askUser, sessionId)` + a shared
  `confirmViaUser(askUser, {...})` in `adapters/interaction.ts`; each adapter only
  formats the normalized result into its transport shape.

### T2 — Remove file-level `eslint-disable no-explicit-any`

- **Where:** `adapters/pi.ts:17`, `adapters/acp.ts:17`, `adapters/codex.ts:16`.
- **Fix:** define minimal wire interfaces for the handful of frames actually
  consumed, parse to `unknown`, narrow with type guards at the top of
  `handleLine`, and drop the file-level disable. Confine `any` to the single
  `JSON.parse` boundary.

## Verification (definition of done)

- Existing adapter tests (`pi.test.ts`, `acp.test.ts`, `codex.test.ts`,
  `*-map.test.ts`) pass **unchanged** — this is behavior-preserving. Add focused
  tests for `spawnLineProcess` (settle/replay/EPIPE-swallow) and
  `TurnStatusTracker`.
- `cd server && pnpm typecheck && pnpm test` green; no new `eslint-disable`.
- Net line count in `adapters/` decreases; `pi.ts` no longer materially larger
  than `acp.ts`/`codex.ts` once `pi-map.ts` exists.

## Non-goals

- No protocol/wire changes. No new agent support. No changes outside
  `server/src/adapters/**` (except the new files therein).
