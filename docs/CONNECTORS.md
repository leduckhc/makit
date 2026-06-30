# Agent Connectors — The pino Adapter Protocol

**Goal:** Any developer can write an adapter (connector) for their agent without forking pino code. Connectors run in-process alongside agents and translate their native tool schemas into a canonical language pino understands.

## Architecture

```
┌─────────────────────────────────────┐
│   Agent Process                     │
│   (pi, codex, claude, piano, etc.)  │
│                                     │
│  ┌─────────────────────────────┐   │
│  │ Agent Connector             │   │
│  │ (pino-pi.ts, pino-codex.ts) │   │
│  │                             │   │
│  │ Native Tool Params          │   │
│  │      ↓                      │   │
│  │ UICall (canonical)          │   │
│  │      ↓                      │   │
│  │ HTTP POST to bridge         │   │
│  └─────────────────────────────┘   │
└──────────────────┬──────────────────┘
                   │
         ┌─────────▼──────────┐
         │ Loopback Bridge    │ http://127.0.0.1:PORT/uicall
         │ (bridge.ts)        │ ± Bearer token
         └──────────┬─────────┘
                    │
   ┌────────────────▼────────────────┐
   │ pino Server                     │
   │                                 │
   │ srv.request(UICall)             │
   │      ↓                          │
   │ WS → app                        │
   │                                 │
   └─────────────────────────────────┘
          ▲              │
          │              ▼
          │     ┌─────────────────────┐
          │     │ Flutter App         │
          │     │                     │
          │     │ srv.request         │
          │     │   → showDialog      │
          │     │                     │
          │     │ User picks answer   │
          │     │   → respondTo       │
          │     └─────────────────────┘
          │
     srv.response(UIResponse)
          │
     HTTP POST ←─────┘
          │
   ┌──────▼──────────────┐
   │ Agent Connector     │
   │                     │
   │ Parse UIResponse    │
   │ → callback(answer)  │
   │                     │
   └─────────────────────┘
          │
          └─→ Agent tool returns answer
```

## The Canonical Schemas

### UICall — Agent → Connector → Bridge → Server → App

```typescript
export type UICall =
  | AskUserQuestionCall
  | ConfirmActionCall;

export interface AskUserQuestionCall {
  kind: "askUserQuestion";
  questions: {
    header?: string;
    question: string;
    options: {
      label: string;
      description?: string;
    }[];
    multi?: boolean;
    recommended?: number;
  }[];
}

export interface ConfirmActionCall {
  kind: "confirmAction";
  title: string;
  message: string;
  preview?: string;
  action: string;
}
```

### UIResponse — App → Bridge → Connector → Agent

```typescript
export type UIResponse =
  | AskUserQuestionResponse
  | ConfirmActionResponse;

export interface AskUserQuestionResponse {
  kind: "askUserQuestion";
  indices: number[];
  answers: string[];
  answer?: string;
}

export interface ConfirmActionResponse {
  kind: "confirmAction";
  approved: boolean;
}
```

## Writing a Connector

### 1. File structure

```
server/connectors/
  pino-pi.ts          ← for pi agent
  pino-codex.ts       ← for codex agent
  pino-claude.ts      ← for claude agent
  pino-piano.ts       ← for Milan's piano agent
```

### 2. Export a factory function

The server auto-discovers and loads all `.ts` files in `server/connectors/`:

```typescript
// server/connectors/pino-codex.ts

import { type UICall } from "../src/uicall.js";

/**
 * When the server spawns a Codex session, it injects PINO_BRIDGE_URL +
 * PINO_BRIDGE_TOKEN into the process env. This connector picks them up and
 * registers a tool with Codex. When Codex calls the tool, we translate its
 * params to a UICall, POST to the bridge, and await the user's response.
 */
export async function setupCodexConnector(agentCwd: string): Promise<void> {
  const bridgeUrl = process.env.PINO_BRIDGE_URL!;
  const bridgeToken = process.env.PINO_BRIDGE_TOKEN!;
  const sessionId = process.env.PINO_SESSION_ID;

  // Register a tool with Codex (pseudocode):
  // await codex.registerTool({
  //   name: "ask_user",
  //   handler: async (params) => {
  //     const uicall: UICall = {
  //       kind: "askUserQuestion",
  //       questions: [{
  //         question: params.question,
  //         options: params.options.map((o) => ({
  //           label: o,
  //           description: undefined,
  //         })),
  //       }],
  //     };
  //     const resp = await fetch(`${bridgeUrl}/uicall`, {
  //       method: "POST",
  //       headers: { Authorization: `Bearer ${bridgeToken}` },
  //       body: JSON.stringify({ ...uicall, sessionId }),
  //     });
  //     const answer = await resp.json() as UIResponse;
  //     if (answer.kind !== "askUserQuestion") throw new Error("schema mismatch");
  //     return answer.answers[0];
  //   },
  // });
}
```

### 3. Contract with the server

- **On startup:** server calls `setupConnectorName(cwd)` with the agent process working directory
- **In-process:** connector registers a tool/hook with its agent
- **On tool call:** connector translates native params → `UICall`, POSTs to bridge, awaits `UIResponse`
- **Return:** connector unpacks `UIResponse` and feeds it back to the agent
- **On error:** connector should gracefully handle timeouts, network failures, dismissed dialogs, and invalid responses

## Examples

See:
- [`server/connectors/pino-pi.ts`](./pino-pi.ts) — pi's standard tool call → UICall mapping
- [`server/connectors/pino-piano.ts`](./pino-piano.ts) — minimal skeleton for Milan's piano agent

## Adding a New UICall Kind

If no existing `kind` (like `askUserQuestion`) fits your agent's needs:

1. **Define the schema** in `server/src/uicall.ts`:
   ```typescript
   export interface MyNewUICall {
     kind: "myNewKind";
     foo: string;
     bar?: number;
   }
   ```

2. **Define the response** in `server/src/uicall.ts`:
   ```typescript
   export interface MyNewResponse {
     kind: "myNewKind";
     chosen: string;
   }
   ```

3. **Add a renderer** in `app/lib/ui/widgets/srv_request_handler.dart`:
   ```dart
   case "myNewKind":
     return _MyNewKindDialog(env: env, onResponse: onResponse);
   ```

4. **Test the round-trip** with a debug endpoint (see `server/src/server.ts` → `debug.ask` for the pattern)

---

**Design principle:** The canonical schema is the contract. Agents and app evolve independently as long as they respect UICall/UIResponse. No pino library dependency required to write a connector — just HTTP + JSON.
