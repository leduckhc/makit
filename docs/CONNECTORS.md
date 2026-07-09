# Agent connectors

makit is **agent-agnostic** by design. Different coding agents — pi, codex,
claude-code, custom wrappers like piano — have their own tool schemas and
extension APIs. To bridge any of them into makit's mobile UI, you write a
small per-agent **connector**.

A connector translates the agent's native tool calls into makit's canonical
`UICall` schema. The phone app speaks `UICall` and nothing else, so once
the connector exists, every makit client (current and future) can drive that
agent without code changes.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│   Agent (pi / codex / claude / piano)                          │
│   speaks its own native tool API                               │
└──────────────────────────┬─────────────────────────────────────┘
                           │ tool.execute(params)
                           ▼
┌────────────────────────────────────────────────────────────────┐
│   Agent connector  ── server/connectors/<your-agent>.ts        │
│   maps native params → canonical UICall variant                │
└──────────────────────────┬─────────────────────────────────────┘
                           │ POST /uicall  (loopback HTTPS, Bearer)
                           ▼
┌────────────────────────────────────────────────────────────────┐
│   makit bridge  ── server/src/bridge.ts                         │
│   forwards to askDevice() → srv.request envelope               │
└──────────────────────────┬─────────────────────────────────────┘
                           │ WSS srv.request {kind, ...}
                           ▼
┌────────────────────────────────────────────────────────────────┐
│   makit app  ── SrvRequestHandler dispatches on `kind`          │
│   renders the appropriate Material dialog                      │
└──────────────────────────┬─────────────────────────────────────┘
                           │ WSS srv.response (same id)
                           ▼
                       back through the same chain to the agent
```

## The canonical `UICall` schema

Defined in [`server/src/uicall.ts`](../server/src/uicall.ts). The mirror
on the app side is the dispatcher in
[`app/lib/ui/widgets/srv_request_handler.dart`](../app/lib/ui/widgets/srv_request_handler.dart).

Currently supported `kind`s:

| `kind`              | Use case                                  | Response shape                                              |
| ------------------- | ----------------------------------------- | ----------------------------------------------------------- |
| `askUserQuestion`   | 1–4 multi-choice questions in a wizard    | `{ indices: number[], answers: string[], answer?: string }` |
| `confirmAction`     | Approve/deny a risky action               | `{ approved: boolean }`                                     |

Adding a new variant:

1. Add the interface to `server/src/uicall.ts` (TypeScript side).
2. Add a `_show…` method in `SrvRequestHandler._dispatch` (Flutter side).
3. Document it here.
4. Add a widget test in `app/test/ask_wizard_test.dart` (or a new file
   following the same pattern).

## Writing a connector

The working example is [`server/connectors/makit-pi.ts`](../server/connectors/makit-pi.ts).
A drop-in template lives at [`server/connectors/makit-piano.ts`](../server/connectors/makit-piano.ts).

A connector is a TypeScript file with a `default export` function that
receives the agent's extension API. The function registers tools that:

1. Take agent-native parameters.
2. Translate them into a canonical `UICall`.
3. POST that to the bridge.
4. Translate the `UIResponse` back into whatever shape the agent expects.

Minimum viable connector:

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { UICall, UIResponse } from "../src/uicall.js";

const BRIDGE_URL = process.env.MAKIT_BRIDGE_URL!;
const BRIDGE_TOKEN = process.env.MAKIT_BRIDGE_TOKEN!;
const SESSION_ID = process.env.MAKIT_SESSION_ID;

async function uicall(call: UICall): Promise<UIResponse> {
  const res = await fetch(`${BRIDGE_URL}/uicall`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${BRIDGE_TOKEN}`,
    },
    body: JSON.stringify({ sessionId: SESSION_ID, ...call }),
  });
  if (!res.ok) throw new Error(`bridge: ${res.status}`);
  return (await res.json()) as UIResponse;
}

export default function (api: ExtensionAPI) {
  if (!BRIDGE_URL || !BRIDGE_TOKEN) return;

  api.registerTool({
    name: "my_tool",
    label: "…",
    description: "…",
    parameters: Type.Object({ /* … */ }),
    async execute(_id, params) {
      const resp = await uicall({ kind: "askUserQuestion", questions: [/* … */] });
      // …translate `resp` into your agent's expected return shape…
      return { content: [{ type: "text", text: "ok" }], details: resp };
    },
  });
}
```

## Loading

Connectors are **auto-discovered** at server startup. Anything matching
`server/connectors/*.ts` is passed to every spawned agent process via
`pi -e <path>`. No code changes in makit itself.

You'll see this in the server log:

```
[makit] loading 2 connector(s): makit-pi.ts, makit-piano.ts
```

## Environment contract

Each connector runs **inside** the agent's process. makit injects three env
vars when it spawns the agent:

| Variable             | Purpose                                                                      |
| -------------------- | ---------------------------------------------------------------------------- |
| `MAKIT_BRIDGE_URL`    | Loopback HTTP bridge base URL, e.g. `http://127.0.0.1:54321`                 |
| `MAKIT_BRIDGE_TOKEN`  | Bearer for the bridge — random per server start                              |
| `MAKIT_SESSION_ID`    | makit's sessionId — routes `srv.request` to the right subscribed phones       |

If a connector loads without these set (e.g. you ran `pi` standalone),
it should be a silent no-op — see the `if (!BRIDGE_URL)` guard.

## Security

- **Loopback only.** The bridge listens on `127.0.0.1` and never on the
  LAN interface. Token is required on every request.
- **Token rotates** on every makit server start.
- **Connector code runs with the agent's full permissions.** Treat it
  like server code you wrote, not like a third-party library. Review
  diffs.
- **No state in the connector.** Each request to the bridge is
  independent. The bridge's job is just to fan the question to whichever
  phones are currently subscribed to the session.
