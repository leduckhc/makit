# SPEC-context-auto-compaction — Automatic context compaction near the window limit

**Status:** Implemented (pending iOS e2e environment) · **Priority:** P2 · **Branch:** `feat-compact`
**Depends on:** SPEC-context-usage (per-session context readings), SPEC-mid-turn-steering-and-queue (turn state), SPEC-acp-config-options-unified-composer (control actions)

**Scope:**
- `server/src/session.ts` — threshold detection and auto-trigger policy.
- `server/src/adapters/acp.ts` — route `compact`/`autocompact` control actions to ACP slash-command prompts.
- `server/src/adapters/codex.ts` — route `compact` control action to `thread/compact/start`.
- `server/src/adapters/stub.ts` — simulate compaction for keyless e2e.
- `app/lib/ui/composer/client_commands.dart` — add `/autocompact` and pass optional instructions through `/compact`.

---

## Goal

When a session's context occupancy nears the model's window, makit asks the agent to compact the conversation before the context is full. The user can still trigger compaction manually with `/compact`, and pi-acp users can toggle pi's own auto-compactor with `/autocompact`.

Pi already has this internally; this spec wires it for ACP (pi-acp) and implements the equivalent for codex app-server.

## Decisions

| | decision | why |
|---|---|---|
| **D1** | Auto-compaction triggers at **80%** of the reported context window. | It gives the agent headroom before the hard limit, without starting so early that it interrupts short tasks. |
| **D2** | The trigger resets at **65%** (hysteresis). | A single compaction must not re-arm immediately while the pre-compaction reading is still arriving. |
| **D3** | The trigger fires only when the session is **idle**. | Compaction cannot safely interrupt a running turn on either ACP or codex. |
| **D4** | The trigger is generic: `Session.sendAction("compact")`. | The same threshold logic works for every adapter; each adapter decides whether it can honor the action. |
| **D5** | ACP `compact`/`autocompact` actions become slash-command prompts (`/compact`, `/autocompact on/off/toggle`). | ACP has no native compaction RPC; pi-acp exposes these as built-in slash commands. |
| **D6** | Codex `compact` action calls `thread/compact/start`. | This is codex app-server's native compaction RPC. It runs as a non-user turn and cannot be steered. |
| **D7** | The stub adapter simulates compaction by rolling back its deterministic usage ramp. | Keyless e2e must exercise the real path (usage → threshold → action → lower reading), not just ignore it. |
| **D8** | `/autocompact` is added to the client slash palette, defaulting to `toggle`. | ACP/pi-acp users can enable pi's own auto-compactor; codex has no equivalent and silently ignores the action. |

## Non-goals

- A user-configurable threshold. One conservative default keeps the feature predictable.
- Compaction while a turn is running. Interrupt-then-resend is already `/cancel` + resend; out of scope.
- Estimating context from outside the agent. All readings come from the agent's own reports (SPEC-context-usage).

## Verification

| Layer | Test |
|---|---|
| `session.test.ts` | A reading above 80% while idle calls `sendAction("compact")`; a running turn blocks it; the hysteresis reset re-arms; missing window or low reading never triggers. |
| `acp.test.ts` | `sendAction("compact")` sends `/compact`; `sendAction("autocompact", {mode:"on"})` sends `/autocompact on`; instructions are appended. |
| `codex.test.ts` | `sendAction("compact")` sends `thread/compact/start` for the active thread and emits no user-message echo. |
| `stub.test.ts` | `sendAction("compact")` lowers the deterministic `session.usage` reading. |
| `pnpm typecheck` / `flutter analyze` | No new type or lint issues. |
