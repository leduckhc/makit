# pino UI Transport Architecture

> Status: **design / refining** (no interceptor code yet as of this doc).
> The `AskUserQuestion` shadow in `pino-pi.ts` is a stopgap and is kept until
> the generic interceptor lands.

## Principle

**pino does not reimplement agent tools.** pino is a *UI transport*: it detects
when the agent (pi) wants to show UI, reframes that request into a canonical
shape the iOS app can render, and translates the user's answer back into the
language the agent expects. All tool logic stays in pi / its extensions.

## The two UI channels in pi `--mode rpc`

pi extensions call methods on `ctx.ui`. In rpc mode:

| `ctx.ui` method | rpc behavior | pino can transport? |
| --- | --- | --- |
| `select(title, options)`  | emits `extension_ui_request {method:"select"}` on stdout, awaits `extension_ui_response` | ✅ yes |
| `confirm(title, message)` | emits `extension_ui_request {method:"confirm"}` | ✅ yes |
| `input(title, placeholder)` | emits `extension_ui_request {method:"input"}` | ✅ yes |
| `editor(title, prefill)`  | emits `extension_ui_request {method:"editor"}` | ✅ yes |
| `notify` / `setStatus` / `setWidget` / `setTitle` / `setEditorText` | fire-and-forget `extension_ui_request` (no response) | ⚠️ optional (display only) |
| `custom(factory)`         | returns `undefined` immediately — **no event emitted** (needs a live TUI to draw the component) | ❌ **no** |

`@mammothb/pi-ask`'s `AskUserQuestion` uses `custom`, which is why it cannot be
transported and instead crashes (`undefined.cancelled`) under headless rpc.
That specific tool is handled by the shadow in `pino-pi.ts`.

### Why `ctx.hasUI` is `true` even headless

pi computes `hasUI()` as `uiContext !== noOpUIContext`
(`core/extensions/runner.js`). pino's rpc mode installs a **real** uiContext
(the `select`/`confirm`/`input`/`editor`/`custom` object in
`modes/rpc/rpc-mode.js`), so `hasUI` is `true`. That's why pi-ask 2.1.3 passes
its `if (!ctx.hasUI) throw "requires interactive mode"` guard and proceeds to
`ui.custom()` — which rpc hard-codes to `return undefined` (a `custom` factory
is a TUI closure that can't cross the rpc boundary). pi-ask then reads
`undefined.cancelled` → the crash. Per its docs, pi-ask "requires interactive
mode"; pino is *UI-capable but not a TUI*, so `custom`-based tools can't run.

## Flow (interceptor model)

```
pi extension calls ctx.ui.select/confirm/input/editor
      │
      ▼  pi rpc → STDOUT
{ type:"extension_ui_request", id, method, ...args }
      │
      ▼  PiAdapter.handleLine detects request
REFRAME → canonical UICall  (server/src/uicall.ts)
      │
      ▼  askDevice → WS srv.request → iOS app
app renders the matching widget, user answers
      │
      ▼  WS srv.response → askDevice resolves
TRANSLATE BACK → { type:"extension_ui_response", id, ... }
      │
      ▼  PiAdapter writes to pi STDIN
pi resolves the ui promise → extension continues → tool result to model
```

## Proposed method → UICall → response mapping

| pi request | canonical UICall (to app) | app widget | app response | `extension_ui_response` back to pi |
| --- | --- | --- | --- | --- |
| `select` (title, options[]) | `askUserQuestion` (1 question, options) | wizard (single-select) | `{answers:[label], indices:[i]}` | `{ value }` (or `{ cancelled:true }`) |
| `confirm` (title, message) | `confirmAction` (title, message) | approve/deny dialog | `{approved}` | `{ confirmed }` (or `{ cancelled:true }`) |
| `input` (title, placeholder) | `input` *(NEW kind)* | text field | `{value}` | `{ value }` (or `{ cancelled:true }`) |
| `editor` (title, prefill) | `input` *(NEW, multiline)* | multiline editor | `{value}` | `{ value }` (or `{ cancelled:true }`) |

## Correlation / lifecycle

- pi's `extension_ui_request.id` is the correlation key. PiAdapter keeps a map
  `id → pending`. It issues a `srv.request` (its own id) to the app, awaits the
  `srv.response`, then emits `extension_ui_response` with the **original pi id**.
- Cancellation: app "Cancel" → `{cancelled:true}` in the canonical response →
  translated to the per-method cancel shape (`{cancelled:true}` / value:undefined).
- Timeout: PiAdapter should time out and send a cancel response so pi doesn't hang.
- Fire-and-forget methods (`notify`, `setStatus`, …) need no response; optionally
  surface as lightweight app toasts/badges later.

## Two layers, clearly separated

1. **Connector-provided tools** (`server/connectors/*.ts`): pino *adds* its own
   tools (e.g. a phone-native `askUserQuestion`) via `registerTool`. Explicit,
   opt-in, pino owns them.
2. **UI interceptor** (`PiAdapter`): pino *transparently transports* any
   extension's standard `ctx.ui.*` calls. pino owns nothing; it only translates.

Both feed the same `askDevice` → app path and reuse the canonical UICall types.

## Open design questions

1. Add a new `input` UICall kind (for `ui.input` + `ui.editor`)? Or reuse the
   generic `_showGeneric` text dialog already in `srv_request_handler.dart`?
2. `ui.select` → single-question `askUserQuestion`, or a dedicated lighter
   `select` kind? (Wizard is heavier than a single list.)
3. Do we surface fire-and-forget `notify`/`setStatus` in the app at all?
4. Keep the `AskUserQuestion` shadow permanently, or retire it if `@mammothb/pi-ask`
   gains a non-`custom` path?
