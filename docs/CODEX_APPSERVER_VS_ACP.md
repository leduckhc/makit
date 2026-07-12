# Codex: app-server vs. ACP (codex-acp) — comparison

Two ways makit can drive Codex, both now implemented behind the `AgentAdapter`
seam and selectable in the agent picker:

- **`codex-native`** → `CodexAppServerAdapter` speaking Codex's first-party
  **app-server** protocol (JSON-RPC over stdio: `initialize` → `thread/start` →
  `turn/start`, streaming `ServerNotification`s, server→client `ServerRequest`s).
- **`codex`** → `AcpAdapter` + the third-party **codex-acp** bridge (ACP v1).

## Live results (same prompt, `gpt-5.4-mini`)

| | codex-native (app-server) | codex (codex-acp / ACP) |
|---|---|---|
| Handshake to ready | **~1.3 s** | ~0.5 s |
| First token | ~3.9 s | ~4.8 s |
| Total turn | **~4.3 s** | ~5.4 s |
| Answer | `4` ✅ | `4` ✅ |
| Event kinds | user.message, agent.message(.delta), session.status | + **session.commands** (slash palette) |

Both stream correctly through makit. codex-acp additionally advertises a slash
command palette today (we map ACP `available_commands_update`); the native path
has the data (`skills/list`, `model/list`) but we don't surface it yet.

## User-ask-questions (the decisive axis)

This is where the two diverge most.

### app-server — first-class, structured
Codex exposes a **native** server→client request: `item/tool/requestUserInput`.

```
questions: [{ id, header, question, isOther, isSecret, options: [{label, description}] | null }]
autoResolutionMs
→ response: { answers: { [questionId]: { answers: string[] } } }
```

This maps **1:1** to makit's `askUserQuestion` UICall: multiple questions,
per-question header, labelled options with descriptions, secret inputs, "other"
free-text, and an auto-resolution timeout. `CodexAppServerAdapter` renders it as
`awaiting-input` and returns answers keyed by question id. It *also* has native,
purpose-built approvals:
- `item/commandExecution/requestApproval` (with parsed command actions, network context, execpolicy amendments, per-decision options),
- `item/fileChange/requestApproval`,
- `item/permissions/requestApproval`,
- `mcpServer/elicitation/request` (`form` / `openai/form` / `url` modes),
- legacy `execCommandApproval` / `applyPatchApproval`.

So "ask the user a question" is a **stable, structured, first-party channel**.

### codex-acp — squeezed through ACP
ACP has no equivalent structured-questions request. codex-acp can only surface:
- `session/request_permission` — approve/deny style options (we map to `confirmAction`),
- `unstable_createElicitation` — **`unstable_`**, "may be removed or changed at any point".

Codex's native `requestUserInput` has **no faithful ACP representation**; it gets
flattened into a permission/elicitation prompt or dropped. So on the exact thing
you care about — **user ask questions — the ACP path is strictly lossier and
depends on an unstable ACP extension**, while app-server is native and richer.

## Other differences

| Aspect | app-server (native) | codex-acp (ACP) |
|---|---|---|
| Thinking/reasoning | ✅ `item/reasoning/*` | ✅ `agent_thought_chunk` |
| Tool taxonomy | Rich: commandExecution, fileChange, mcpToolCall, dynamicToolCall, webSearch, imageGeneration, review, subagents… | Generic ACP `tool_call` (kind/title/diff) |
| Diffs | `item/fileChange` + patch status | ACP structured `diff` content |
| Command output | `item/commandExecution/outputDelta` | `_meta.terminal_output` (Zed convention) |
| Slash commands | `skills/list`, `model/list` (not yet mapped) | ✅ `available_commands_update` (mapped) |
| Approvals fidelity | High (parsed actions, amendments, scopes) | Binary-ish permission options |
| Guardian auto-approve | server-side (intercepts low-risk) | same (server-side) |
| Dependency | first-party `codex` binary; **experimental** protocol, "may change without notice" | third-party Zed bridge (embeds codex-core; MIT); tracks codex |
| Auth/models | direct via `~/.codex` | direct via `~/.codex` |

## Tradeoff & recommendation

- **app-server = higher fidelity, first-party, but an *experimental* protocol.**
  Best for a tier-1 Codex experience — especially interactive question flows,
  which are native and structured. Cost: the protocol may shift; more surface to
  map (100+ methods) and it's codex-specific.
- **codex-acp = one ACP integration for all agents, lower interaction fidelity**
  and reliant on `unstable_` elicitation for questions. Best for breadth.

**For makit, given the emphasis on user-ask-questions: prefer `codex-native`
(app-server) as the Codex path** — it's the only one that carries Codex's
structured `requestUserInput` losslessly into `askUserQuestion`. Keep `codex-acp`
as the portable fallback and for the shared multi-agent ACP surface. Both remain
selectable per session.

> Caveat: `item/tool/requestUserInput` is gated/experimental in current Codex
> (`default_mode_request_user_input` is "under development"), so it may not fire
> for every model/config yet. The adapter is ready for it the moment it does.
