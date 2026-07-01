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

---

## Postmortem: the `AskUserQuestion` "cancelled" crash (resolved)

### Symptom
In the app, the agent's `AskUserQuestion` tool errored with:

```
AskUserQuestion -> Cannot read properties of undefined (reading 'cancelled')
```

Confusingly, a **lowercase** `askUserQuestion` worked while the **capital**
`AskUserQuestion` failed — same session, same schema.

### Investigation (what threw us off)
1. `cancelled` is written by the app on cancel, but **never read** by pino's
   server/connector — so the crash was **inside pi**, not our code.
2. We first assumed our bridge response shape was wrong. It wasn't; a
   standalone rpc repro (real `pi` + `pino-pi.ts` + a mock bridge returning a
   well-formed response) completed cleanly.
3. Capital `AskUserQuestion` turned out **not to be our tool** at all — it is
   the user's global extension **`@mammothb/pi-ask`** (a Claude-Code-style
   ask tool). Lowercase `askUserQuestion` was pino's own connector tool.

### Root cause
- `@mammothb/pi-ask` renders its form with **`ctx.ui.custom(factory)`** — a
  closure that draws a live TUI component.
- pino drives pi **headless** (`pi --mode rpc`). In rpc, `ui.custom()` is
  hard-coded to `return undefined` (the factory can't cross the rpc boundary).
- pi-ask guards with `if (!ctx.hasUI) throw`. But `hasUI` is
  `uiContext !== noOpUIContext`, and **rpc installs a real uiContext**, so
  `hasUI === true`. pi-ask passes the guard, calls `custom()`, gets `undefined`,
  then does `undefined.cancelled` → the crash.
- pino's own `askUserQuestion` connector uses the **HTTP bridge → phone**, which
  works fine in rpc. That's why lowercase worked and capital didn't.

Separately, a **real** bug was found and fixed while chasing this: the server
bridge unwrapped `env.body` (undefined — envelopes are flat), so *every*
askUserQuestion through the live server returned undefined. Fixed to `return env`
(commit "fix(bridge): return the flat srv.response envelope, not env.body").

### Resolution
- **Short term (shipped):** `pino-pi.ts` registers a pino-native ask under both
  `AskUserQuestion` and `askUserQuestion`. pi resolves duplicate tool names by
  "first registration wins" and pino connectors load first, so it cleanly
  supersedes `@mammothb/pi-ask` (pi logs `Tool "AskUserQuestion" conflicts …`
  and skips it). The phone wizard now answers whichever casing the model emits.
- **Long term (designed + POC-proven):** the **interceptor** above. pino
  transports pi's standard `ctx.ui.select/confirm/input/editor` calls to the
  phone and back, without owning tools. Proven end-to-end in `server/poc/`
  (`poc-ui-ext.ts` + `poc-interceptor.mjs`): select/confirm/input all
  round-trip. `ui.custom` remains un-transportable by design, so `custom`-based
  extensions (like pi-ask) still need a native pino tool.

### Rules of thumb for the future
- A tool error prefixed `ToolName -> …` is thrown **inside pi / the extension**,
  not in pino. Reproduce with a standalone `pi --mode rpc -e <ext>` + a mock
  bridge before touching pino code.
- `hasUI` is **true** under pino rpc. Extensions *will* attempt UI. Only
  `select/confirm/input/editor` emit `extension_ui_request`; `custom` silently
  returns `undefined`.
- Keep test harnesses (e.g. `e2e-server.ts`) byte-identical to production wiring
  for shared code paths — the `env` vs `env.body` divergence hid a live bug
  behind green stub tests.
