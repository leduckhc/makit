# Client capabilities

> The app is a thick client, not a dumb viewer. Like LSP, both sides advertise
> what they can do; either side can drive the other.

## Layers

```
┌────────────────────────────────────────────────────────────────┐
│  Agent (pi)        — tool calls, prompts, model responses      │
├────────────────────────────────────────────────────────────────┤
│  Server (pino)     — registry, fan-out, agent adapter, auth    │
├────────────────────────────────────────────────────────────────┤
│  App (Flutter)     — chat, slash palette, tool renderers,      │
│                      "client commands", UI request handlers    │
└────────────────────────────────────────────────────────────────┘
```

There are **three** distinct kinds of "thing the user can trigger":

| Kind                  | Lives in       | Examples                                  |
| --------------------- | -------------- | ----------------------------------------- |
| **Agent commands**    | pi (`get_commands`) | `/skill:cavemen`, `/fix-tests`, `/session-name` |
| **Server commands**   | server         | `session.spawn`, `session.kill`, `set_policy` |
| **Client commands**   | app only       | `/new`, `/unpair`, `/clear`, `/help`      |

The slash palette merges all three. The composer routes by source:
- Agent commands → wrapped in `cmd: send.message` → server → pi
- Server commands → sent as their own `cmd` kinds
- Client commands → handled locally in Dart, never leave the device

## Reverse direction: UI requests

Some agent capabilities require user input from a **specific** device:
`ask_user_question`, `pick_file`, `confirm_destructive`, `show_diff`. The agent
can't reach the phone directly — pino brokers it via a new envelope:

```
agent → pi → pino server → app  (srv.request)
app → user → app → pino server → pi → agent (srv.response)
```

Protocol:

```ts
// server → client
{ t: "srv.request", id, sessionId, kind: "ask_user_question",
  payload: { questions: [...] }, callId }

// client → server
{ t: "srv.response", id, callId, ok: true, data: { answers: {...} } }
{ t: "srv.response", id, callId, ok: false, reason: "user cancelled" }
```

`callId` correlates the request back to the originating agent tool call.

## Capability negotiation

On `hello`, both sides advertise capability strings. Either side can use a
capability only if it sees it in the other's `caps` list.

```ts
// client → server
hello { bearer, caps: ["chat.send", "approval.respond",
                       "ui.ask_user_question", "ui.pick_file",
                       "command.new_session"] }

// server → client
hello.ack { ok, caps: ["session.spawn", "session.policy", "session.commands"] }
```

Anything not in the list is a hard "not supported, please don't ask".

## Tool rendering

Independent from capabilities. Each `tool.call.start` event carries a `name`.
The app's `ToolRendererRegistry` looks up a renderer by name and falls back
to a generic card. Renderers can:

1. Customize the **collapsed card** in chat (e.g. show `+12 −3` for `edit`).
2. Customize the **fullscreen drilldown** (e.g. unified diff viewer for `edit`,
   command output terminal for `bash`).
3. Be **interactive** when the tool is also a UI request — e.g. an
   `ask_user_question` card with tappable answer chips that emit `srv.response`.

Built-in renderers (M3):
- `bash` — command + streaming output, monospace
- `read` — path + content preview
- `edit` / `write` — path + diff
- `ask_user_question` — interactive multi-choice
- generic — current behaviour

## Roadmap

- ✅ M2 — client command registry (/new, /unpair, /help). Slash palette merges all sources.
- 🟡 M3 — tool renderer registry. Custom cards for bash/edit/read. Static `ask_user_question` renderer (display-only).
- 🟡 M3+ — pino-pi extension that registers `ask_user_question` and friends as agent tools, forwarding to the app via `srv.request`. This is the round-trip.
- 🟡 M4 — capability negotiation in `hello`. Until then we assume a fixed v1 set.
