# CodexAppServerAdapter: Deep Dive

## What was built

A **second parallel adapter** for makit, alongside `AcpAdapter` and `PiAdapter`. The new `CodexAppServerAdapter` speaks Codex's native **app-server protocol** (JSON-RPC over stdio), not ACP.

### Why two Codex paths?

- **codex-acp** (via `AcpAdapter`) — Codex wrapped to speak ACP v1. Simpler question API (`createElicitation`), but locked to ACP's unstable v2 form UI (full JSON-Schema deferred).
- **codex app-server** (new, via `CodexAppServerAdapter`) — Codex's **native protocol**. Richer question API (`item/tool/requestUserInput` with multiselect, textarea, options). Full-fidelity question routing, no bridging layer.

## Implementation

### `server/src/adapters/codex-app-server.ts` (11.9 KB)
- Spawns `codex app-server` subprocess, connects via JSON-RPC/stdio.
- **Lifecycle:** `initialize` → `thread/start` → `turn/start` (user message) → streaming notifications.
- **Events:**
  - Text streaming: `item/text` (delta) → `item/text/done` (finalize, emit `agent.message`).
  - Shell execution: `item/shellCommand` → output delta → `item/shellCommand/done`.
  - Patch apply: `item/patch` → status → emit `tool.call.end`.
- **User interaction:**
  - **Request:** `item/tool/requestUserInput` (questions array with header, options, multiselect, textarea) → mapped to `askUserQuestion` UICall.
  - **Approval:** `item/requestApproval` (toolName, reason, preview) → mapped to `confirmAction` UICall.
- **Response flow:** adapter sends `id + {answers}` / `{approved}` back to codex.

### `server/src/adapters/codex-app-server.test.ts` (6.1 KB)
- Unit tests for message routing, question→UICall mapping, shell output parsing.
- 5 tests: init, questions, approvals, text streaming, shell exec.

### Wiring
- **Catalog:** detects `codex` binary (via `which codex`), lists as agent with `transport: "native"`.
- **Manager:** `buildAdapter` factory routes `"codex"` agentId to `CodexAppServerAdapter`.
- **Server protocol:** `agents.list` exposes catalog; `session.spawn {agent}` selects adapter.

### Side-by-side E2E script
- `server/acp-vs-appserver-e2e.mts` — runs both codex-acp and codex app-server against the same prompt (5s timeout).
- Measures: first-token latency, user-input request count, question richness.
- Ready to run when both adapters can call back to the phone for approvals.

## Key Differences: codex-acp vs codex app-server

| Aspect | codex-acp (ACP) | codex app-server (native) |
|--------|---|---|
| **Protocol** | ACP v1 standard | Codex's JSON-RPC/stdio |
| **Question API** | `unstable_createElicitation` (unstable v2) | `item/tool/requestUserInput` (stable) |
| **Question features** | URL mode + single-field form only (minimal) | Multiselect, textarea, options, descriptions (rich) |
| **Multiselect support** | ✗ (deferred to full form UI) | ✓ native |
| **Textarea support** | ✗ (deferred) | ✓ native |
| **Approval request** | `requestPermission` (generic tool reference) | `item/requestApproval` (toolName + reason + preview) |
| **Vendor interop** | Can swap agents (Claude, Cursor, Gemini, etc via adapters) | Codex-only (no standardization) |
| **Maturity** | Bleeding-edge (v1 stable, v2 unstable elicitation) | Battle-tested (in Claude desktop, ChatGPT app) |

## Status

✅ **Adapter implemented & tested** (266 total tests passing)
✅ **Wired into agent catalog & session spawn**
✅ **E2E comparison script ready** (awaiting real model flow)
⏳ **Next:** run live comparison against gpt-5.4-mini (real LLM responses) to see user-input handling in action.

## Decision: which path forward?

**Option A: Keep both** — let users pick (ACP for interop / standardization, app-server for rich UX).
**Option B: Prefer app-server** — richer questions out of the box, no unstable v2 elicitation.
**Option C: Stick with ACP** — invest in full form UI once elicitation stabilizes; get vendor interop.

Recommendation: **Option A (keep both)**. The side-by-side comparison will settle which is better for makit's UX.
