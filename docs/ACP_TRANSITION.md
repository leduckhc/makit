# ACP Transition Implementation

## Overview

Makit now supports the **Agent Client Protocol (ACP) v1** alongside the existing native pi adapter. The implementation adds a generic `AcpAdapter` that:

1. **Spawns ACP agent subprocesses** (default: `pi-acp`, but any ACP v1 agent)
2. **Translates ACP events → makit SessionEvents** (via `AcpEventMapper`)
3. **Handles tool permissions and file I/O** via bidirectional ACP RPC (`session/request_permission`, `fs/read_text_file`, `fs/write_text_file`; terminal delegation is not advertised — pi-acp runs commands locally)
4. **Seamlessly integrates with makit's UI bridge** (phone approval flow, WebSocket, etc.)

This enables makit to:
- Leverage **any ACP-compliant agent** (not just pi)
- Adopt the standardized ACP protocol (interoperability)
- Maintain **backward compatibility** with the existing PiAdapter

## Architecture

### Files Added

```
server/src/adapters/
├── acp-map.ts              (new) AcpEventMapper: ACP session/update → AdapterEvent
├── acp-map.test.ts         (new) 9 unit tests for the mapper
├── acp.ts                  (new) AcpAdapter: AgentAdapter implementation + subprocess transport
└── acp.test.ts             (new) 4 lifecycle/permission tests (in-process fake ACP agent)
```

### Dependencies Added

- `pi-acp@0.0.31` — Official ACP adapter for pi (production-grade: ~4.2k LoC + ~2.9k LoC tests)
- `@agentclientprotocol/sdk@0.26.0` — ACP client SDK (already bundled in pi-acp)

## Event Mapping

### ACP SessionUpdate → makit SessionEvent

The `AcpEventMapper` translates ACP's session update variants to makit's event kinds:

| ACP SessionUpdate | makit AdapterEvent | Notes |
|-------------------|------------------|-------|
| `user_message_chunk` | `user.message` | Only during session/load history replay |
| `agent_message_chunk` | `agent.message.delta` + `agent.message` | Streaming deltas + final (stable msgId), finalized on turn end / stream switch |
| `agent_thought_chunk` | `agent.thinking.delta` + `agent.thinking` | Separate stream from message text |
| `tool_call` | `tool.call.start` | title→name, kind→risk class, rawInput→args |
| `tool_call_update` | `tool.call.delta` / `tool.call.end` | Output accumulation (bash via `_meta`); `end` on status completed/failed |
| `available_commands_update` | `session.commands` | Slash command palette (source: `command`) |
| `session_info_update` | (title) → adapter `title` event | Agent-driven session rename |
| (others) | — | plan/plan_update, current_mode_update, config_option_update, usage_update (future) |

There is no `tool_call_result` / `error` update in ACP v1 — tool completion is a
`tool_call_update` with `status: completed|failed`, and turn/prompt failures are
surfaced by the adapter as `session.error` when `session/prompt` rejects.

### Bash/Terminal Output (pi-acp convention)

pi-acp uses `_meta.terminal_output.data` (stdout) and `_meta.terminal_exit` (exit code) to encode bash command results. The mapper automatically extracts these and classifies the risk (success / failure / abort).

## Permission/UICall Flow

When the agent sends a `session/request_permission` RPC (e.g. before a risky
tool call), the `AcpAdapter`:

1. Receives `requestPermission` on its ACP `Client` handler
2. Maps the request to a makit `confirmAction` `UICall` (title = the tool-call title)
3. Bridge sends it to the Flutter app over WebSocket via `askUser`
4. User approves/denies → `askUser` resolves
5. Adapter picks the matching ACP `PermissionOption` (an `allow_*` option on
   approve, a `reject_*` option on deny) and returns a `RequestPermissionResponse`
6. If no phone is attached, the adapter **fails safe**: it selects a reject
   option when one exists, otherwise returns `outcome: cancelled`

While a permission request is outstanding, the session is reported as
`awaiting-approval` (the app already renders this as an "approve" badge + a
"needs your approval" notification); it returns to `running` once the user
decides. The `confirmAction` payload carries a kind-specific title, the tool's
description as the message, and a `preview` of the command / diff being approved.

`askUser` is supplied per-session through `AgentAdapter.start({ askUser })` —
the same bridge callback PiAdapter uses — not through the constructor.

Note: pi's richer `ctx.ui.*` dialogs (free-text input/editor) are intentionally
**not** bridged on the ACP path (see the transition decision); only tool
permissions are surfaced.

### Elicitation (`unstable_createElicitation`) — minimal

The adapter implements ACP v1's unstable elicitation extension at a minimal
scope (codex-acp uses it):

- **url mode** → `confirmAction` showing the message + URL as preview; approve
  returns `{action:"accept"}`, deny `{action:"decline"}`, dismiss `{action:"cancel"}`.
- **single-field form** → `input` UICall; the typed value is coerced to the
  field's declared type (number/integer/boolean/string) and returned as
  `{action:"accept", content:{<field>: value}}`.
- **multi-field / empty form** → `{action:"decline"}` without prompting (the
  full JSON-Schema form UI is deferred).
- **no phone attached** → fail-safe `{action:"decline"}`.

Elicitation reuses the same `awaiting-approval` status gating as permissions.
`unstable_completeElicitation` is a no-op (URL flows complete out of band).

## Configuration

### Per-session agent selection (app picker)

Agents are chosen **per session** from the app. The server exposes a catalog
(`server/src/adapters/catalog.ts`) via the `agents.list` command:
`pi` (native) and `pi-acp` are always listed (with `available` reflecting binary
presence); `codex` (via `codex-acp`) is listed only when a codex-acp binary is
detected (`MAKIT_CODEX_ACP_BIN` or on PATH). `session.spawn` accepts an optional
`agent` id; native pi keeps the multiplexer-pane path, ACP agents run headless.
The app fetches the catalog on `+` and shows a bottom-sheet picker (skipped when
only one agent is available). `MAKIT_AGENT` remains the default when no `agent`
is specified.

### Default agent

**As of this update, ACP is the default agent path.** Makit now spawns `pi-acp` by default.
To use the native PiAdapter (legacy, will be removed), set `MAKIT_AGENT=pi`:

```bash
MAKIT_AGENT=pi makit serve
```

Or in code:

```typescript
const manager = new SessionManager({
  projects: [projectPath],
  agentType: process.env.MAKIT_AGENT === "pi" ? "pi" : "acp",
});
```

### Custom ACP Agent

`AcpAdapter` takes a spawn spec, so any ACP v1 agent works:

```typescript
new AcpAdapter({
  spec: {
    agent: "claude",              // makit agent label
    command: "claude-agent-acp",  // or "codex-acp", etc.
    args: [],
    env: { ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY! },
  },
});
```

Tests inject a fake in-process agent via the `connect` seam instead of spawning
a subprocess:

```typescript
new AcpAdapter({ spec: { agent: "pi", command: "x" }, connect: () => transport });
```

## Testing

All existing tests pass (249). New tests added:

- **9 acp-map.test.ts tests**: streaming deltas/finalization, thinking-vs-message stream separation, tool-call lifecycle, risk classification by kind, bash output/exit via `_meta`, failed tool calls, command palette, title updates, history replay
- **4 acp.test.ts tests**: full turn end-to-end, permission approval via askUser, fail-safe deny with no phone, exit on kill (all driven by an in-process fake ACP agent over paired in-memory streams — no subprocess, no real pi)

Run full suite:
```bash
pnpm test
```

Run ACP tests only:
```bash
pnpm test -- src/adapters/acp-map.test.ts src/adapters/acp.test.ts
```

## Integration Status

✅ **Adapter added & tested**
✅ **Installed pi-acp@0.0.31 (production-grade)**
✅ **Wired into SessionManager**
✅ **ACP is now the default** (PiAdapter available via `MAKIT_AGENT=pi`)

⏳ **Next steps:**
- Remove native PiAdapter (when ready)
- Add UI to switch agent types at runtime
- Test with real agents (Claude, Codex via ACP adapters)
- Document ACP agent onboarding for end-users

## Backward Compatibility

- **PiAdapter available as fallback**: Set `MAKIT_AGENT=pi` to use the native adapter (will be removed in a future release)
- **No breaking changes** to the SessionManager or Session APIs
- **Adapter interface unchanged** (both implement `AgentAdapter`)

## Architecture Decision

Instead of **replacing** PiAdapter with AcpAdapter, we **added** it as an alternative, with ACP as the new default. This allows:

1. **Seamless transition**: New code paths default to ACP
2. **Fallback for critical issues**: `MAKIT_AGENT=pi` recovers to native adapter
3. **Future removal path**: PiAdapter can be deleted once ACP maturity is proven
4. **Multi-agent support**: Easier to onboard Claude, Codex, etc. via their ACP adapters

---

**Protocol Docs**: See `~/Work/Vibe/acp-docs/` for full ACP v1 specification.
