# SPEC-acp-config-options-unified-composer — ACP session config options + unified composer config model

**Status:** Proposed · **Priority:** P2 · **Surface:** server ACP adapter (`server/src/adapters/`), desktop + mobile composer selectors (`app/lib/ui/composer/`), wire protocol
**Depends on:** SPEC-server-adapter-consolidation (server adapter consolidation), the ACP transition work (`docs/ACP_TRANSITION.md`). *Foundation for SPEC-new-session-config-at-spawn (new-session config) and SPEC-desktop-workspace-tabs (workspace tabs), which build on this config model.*

---

## Problem

Two gaps in how makit handles an ACP session's configuration (the composer +
the pre-spawn dialog). Note the timing nuance: ACP `configOptions` are returned
in the **`session/new` response (session setup)**, i.e. before the first prompt
— not after a turn. SPEC-new-session-config-at-spawn **caches** each harness's `configOptions` (populated
by a one-time throwaway `session/new` in a temp `cwd`, keyed by a harness
fingerprint), so the new-session dialog renders them from cache with **no eager
session** and applies picks at launch. This spec owns the adapter + composer
config plumbing that both the cached catalog and the running-session composer
depend on.

1. **The makit ACP adapter is behind the ACP spec.** It only maps the legacy
   `modes` API (`server/src/adapters/acp.ts` — `captureModes`,
   `setSessionMode`, `ComposerModeSelector`) and hardcodes *"ACP has no
   model/thinking."* ACP v1 has since added **Session Config Options**
   (`configOptions`), a generic list of agent-provided selectors that
   **supersedes `modes`** (modes will be removed). Via `configOptions` an ACP
   agent can expose a **model** selector, a **reasoning** selector
   (`thought_level`), speed/quality + context (`model_config`), the **mode**,
   and boolean toggles. makit currently drops all of that except modes.

2. **makit's composer config is a hardcoded triple.** The composer has three
   bespoke widgets — `ComposerModelSelector`, `ComposerThinkingSelector`,
   `ComposerModeSelector` — driven by `SessionMeta {model, thinking, models,
   modes}`. This shape can't represent ACP's arbitrary, categorised, dependent
   `configOptions` (nor future native options), and duplicates logic across the
   three widgets.

## Goal

- **Adopt ACP `configOptions`** in the ACP adapter (send/receive), keeping
  `modes` only as a back-compat fallback for agents that don't emit
  `configOptions`.
- **Unify the composer's session config** onto one generic model — a list of
  **config options** with semantic **categories**. The composer renders this
  **one** category-driven model through a single renderer — replacing the three
  bespoke widgets. **Two transports feed it:** ACP harnesses (pi via `pi-acp`)
  map `configOptions` natively; the **codex `app-server`** adapter
  (`codex-native`) **projects** its model + reasoning-effort surface into the
  same `SessionConfigOption` shape. (`codex-acp` is the ACP target for codex —
  not yet implemented; when it ships codex moves to the ACP `configOptions`
  mapping with no client/wire change.)
- **Timing-agnostic plumbing.** This spec covers the adapter + composer config
  model; the ACP config catalog is **cached** by SPEC-new-session-config-at-spawn (one-time throwaway
  `session/new`); picks apply at launch. Either way the composer must render/set
  `configOptions` for a live session.

---

## Background: ACP Session Config Options (v1)

Source: <https://agentclientprotocol.com/protocol/v1/session-config-options>

**Lifecycle / timing (important, verified against the spec):** the ACP phases are
`initialize` → `session/new` → `session/prompt`. `configOptions` are returned in
the **`session/new` response** — the page's "Initial State" example is a JSON-RPC
result that carries **`sessionId`**, which only `session/new` returns. The
doc-section named "Session Setup" is the phase that *contains* `session/new`, not
a step before it. **`initialize` carries no `configOptions`** (only
`agentCapabilities`: loadSession, mcp, sessionCapabilities, prompt, auth). So
config is known **at `session/new`, before the first prompt**, but **not before
`session/new` itself** — there is no earlier RPC to read it from. Consequence:
surfacing ACP config pre-first-message requires calling `session/new` (which
needs `cwd`) — but only **once**, for a cached catalog (SPEC-new-session-config-at-spawn), via a throwaway
`session/new` in a temp dir; no eager session per new-session. This applies to
**ACP harnesses** (pi via `pi-acp`); **codex uses `app-server`** (`codex-native`)
whose config surface is projected into the same model (see below).

- Returned in the **`session/new`** response as `configOptions: ConfigOption[]`
  (and updated mid-session via a `config_option_update` session notification).
- `ConfigOption = { id, name, description?, category?, type, currentValue,
  options? }`. `type` is `select` (default) or `boolean` (only if the client
  advertises `session.configOptions.boolean: {}` in `clientCapabilities`).
- **Categories** (semantic, UX-only): `mode`, `model`, `model_config`
  (context/speed–quality), `thought_level` (reasoning). Unknown/missing handled
  gracefully; `_`-prefixed are custom.
- Set via **`session/set_config_option` { sessionId, configId, value }**; the
  agent replies with the **complete** option list (so dependent options — e.g.
  model → available reasoning — recompute). The agent MAY also push updates.
- **Ordering matters** (agent's preferred priority). Agents MUST always have a
  default per option.
- **Supersedes `modes`.** During transition an agent MAY send both; a client
  that supports `configOptions` uses it exclusively and ignores `modes`.

---

## Current-state anchors (real code this reshapes)

- `server/src/adapters/acp.ts` — `captureModes`, `emitMeta` (payload `{model,
  thinking, models, modes}`), `handleAction("mode")` → `setSessionMode`,
  `current_mode_update` handling, `clientCapabilities` on initialize.
- `server/src/adapters/acp-map.ts` — session-update mapping.
- `server/src/adapters/pi.ts` — the native pi adapter; **removed** by SPEC-new-session-config-at-spawn
  (pi runs via `pi-acp` through `AcpAdapter`). Its `get_state`/
  `get_available_models`/`set_model`/`set_thinking_level` are no longer used.
- `server/src/adapters/codex.ts` — `CodexAppServerAdapter` (drives `codex
  app-server`); **kept**. Gains a **projection** of its model +
  reasoning-effort surface into `SessionConfigOption` (see below).
- `app/lib/store/models.dart` — `SessionMeta {model, thinking, models, modes}`,
  `ModelInfo`, `SessionModes`, `SessionMode`.
- `app/lib/ui/composer/composer_selectors.dart` — `ComposerModelSelector`,
  `ComposerThinkingSelector`, `ThinkingSignal`, `ComposerModeSelector`.
- `app/lib/ui/composer/client_commands.dart` — `/model`, `/thinking` pickers,
  `thinkingLevels`.
- `server/src/protocol.ts` — `session.meta` payload, `session.action`.

---

## Target model

### Wire: generalise `session.meta` config

Introduce a generic, category-tagged option list on `session.meta`, alongside
the existing fields during migration:

```ts
type ConfigOptionCategory = "mode" | "model" | "model_config" | "thought_level" | string;
interface ConfigOptionValue { value: string; name: string; description?: string }
interface ConfigOptionGroup { name: string; options: ConfigOptionValue[] }
interface SessionConfigOption {
  id: string;
  name: string;
  description?: string;
  category?: ConfigOptionCategory;
  type: "select" | "boolean";
  currentValue: string | boolean;
  // select only: either a flat value list OR named groups (ACP allows both).
  options?: ConfigOptionValue[];
  groups?: ConfigOptionGroup[];
}
// session.meta gains:
//   configOptions?: SessionConfigOption[]   // ordered (agent priority)
```

Setting an option → a single control action `session.action` `configOption`
`{ id, value }` (server maps to ACP `session/set_config_option`). The
response/refresh re-emits the **complete** `configOptions` list.

### Server — ACP adapter (`acp.ts`)

- On `session/new`: if the agent returns `configOptions`, capture and emit them
  as `session.meta.configOptions`; **ignore `modes`** when `configOptions` is
  present. If only `modes` is returned, synthesise a single `category:"mode"`
  option from it (back-compat).
- Advertise `clientCapabilities.session.configOptions.boolean: {}` on
  initialize (we support boolean options). **Prerequisite:** the ACP SDK must be
  upgraded to a version that types `session.configOptions` in
  `ClientCapabilities` — the repo currently pins `@agentclientprotocol/sdk`
  `^0.26.0`, which lacks it; `configOptions` lands in the 1.x SDK. This upgrade
  (and any 0.26→1.x breaking-change fixes) is in scope for this spec's first
  step, before boolean options can be advertised type-safely.
- **Grouped select options:** when an agent returns grouped choices, parse them
  into `groups` (preserve group names); flat lists parse into `options`. The
  renderer flattens groups into labeled sections. Add parser + renderer tests
  for both shapes.
- Map the `configOption` action → `session/set_config_option`; handle the
  `config_option_update` notification → re-emit `configOptions`.
- Keep `setSessionMode`/`current_mode_update` only for agents that never send
  `configOptions`.

### Server — pi over ACP (`pi-acp`)

- pi is **not** a special case among ACP agents: it runs through `AcpAdapter`
  via `pi-acp` and emits its own `configOptions` (model / thought_level / …)
  like any ACP agent. The native `pi.ts` projection is deleted; no
  `set_model`/`set_thinking_level` path. (Reintroducing `pi-acp`; its ACP
  file-access is accepted — no extra fs sandboxing planned, see SPEC-new-session-config-at-spawn.)

### Server — codex `app-server` projection (`codex.ts`)

- codex is **not** ACP yet; it runs on `codex app-server`
  (`CodexAppServerAdapter`). This adapter **projects** codex's config surface
  into the same `SessionConfigOption` list the composer/renderer consume:
  - a `category:"model"` select (available models),
  - a `category:"thought_level"` select (reasoning effort:
    minimal/low/medium/high),
  - `currentValue` = the thread's active model / effort.
- Setting an option maps to the app-server's thread/turn params
  (`thread/start`/`turn/start` `model`, reasoning-effort config) rather than
  `session/set_config_option`. The composer path is identical — it only sees
  `SessionConfigOption`.
- **Target:** when `codex-acp` exists, this projection is replaced by the ACP
  `configOptions` mapping with no change to the wire model or composer.

### App — unified composer config (`models.dart`, `composer_selectors.dart`)

- Parse `session.meta.configOptions` into a `List<SessionConfigOption>`.
- Replace the three bespoke selectors with **one category-driven renderer**: a
  row of pills (the existing `_ComposerPill` look), one per option, ordered as
  the agent sent them, rendered by `category`:
  - `model` → model picker (searchable sheet, as today).
  - `thought_level` → the `ThinkingSignal` + level picker.
  - `mode` / `model_config` / unknown → generic select sheet;
    `model_config` rendered next to `model` (spec guidance).
  - `type:"boolean"` → a toggle pill.
- Selecting a value sends `session.action configOption {id,value}`; the composer
  re-renders from the returned complete list (handles dependent options).
- Keep the legacy `model`/`thinking`/`modes` parsing as a fallback while both
  the pi and ACP adapters are migrated; remove once both emit `configOptions`.

---

## Plan (TDD)

Server (`pnpm test`, `pnpm typecheck`):

1. **ACP `configOptions` capture + emit.** `session/new` with `configOptions` →
   `session.meta.configOptions` (ordered), `modes` ignored when both present;
   `modes`-only → synthesised `mode` option.
2. **ACP set + update.** `configOption` action → `session/set_config_option`;
   `config_option_update` → re-emit complete list; boolean capability advertised.
3. **pi over ACP + codex projection.** (a) With a stub ACP adapter emitting
   pi-shaped options (model + `thought_level`), the same capture/emit + set
   path handles them — no pi-specific branch. (b) `CodexAppServerAdapter`
   projects a model + reasoning-effort `SessionConfigOption` catalog and maps a
   `configOption` action onto `thread/start`/`turn/start` params. Test both
   emit the same `SessionConfigOption` shape. (Deleting the native `pi.ts`
   path is **SPEC-new-session-config-at-spawn's** step; until then the legacy-meta fallback covers
   native pi.)

App (`flutter test --no-pub`, `flutter analyze --no-pub`):

4. **Parsing.** `SessionConfigOption` parsing incl. boolean + unknown category
   + ordering; legacy-meta fallback still parses.
5. **Composer renderer.** Widget tests: options render in order by category;
   selecting sends `configOption`; a returned list with changed dependent
   options re-renders; boolean pill toggles.
6. **Green gate.** `flutter analyze --no-pub` clean; `flutter test --no-pub`
   green; `app/tool/audit.sh` passes; server `pnpm test` + `pnpm typecheck`
   green.

---

## Risks & notes

- **Migration window.** The legacy `model/thinking/modes` `SessionMeta` fields
  and the new `configOptions` coexist until both transports emit the unified
  shape — pi (ACP via `pi-acp`) natively, codex (`app-server`) via projection;
  prefer `configOptions` when present, remove legacy after. The native `pi.ts`
  path is deleted outright (SPEC-new-session-config-at-spawn).
- **codex projection is a stopgap.** codex config is projected from `app-server`
  (model + reasoning-effort) rather than native ACP `configOptions`. When
  `codex-acp` exists the projection is swapped for the ACP mapping — no wire or
  composer change (the composer only sees `SessionConfigOption`).
- **`pi-acp` file access (accepted).** Reintroducing `pi-acp` reopens the ACP
  file-access topic PR #25 raised; per project decision this is **accepted — no
  additional fs sandboxing is planned** (SPEC-new-session-config-at-spawn).
- **Dependent options.** The agent returns the *complete* list on every set; the
  composer must fully re-render from it (never merge in place) so model→reasoning
  coupling stays correct.
- **Ordering + unknown categories.** Respect array order; render unknown/missing
  categories with the generic select and never fail.
- **Boolean gate.** Only advertise/accept boolean options behind the client
  capability, per spec.

## Out of scope

- **Where** the ACP session is created (eager pre-spawn vs lazy) — that lifecycle
  choice is SPEC-new-session-config-at-spawn's. This spec is agnostic: it plumbs `configOptions` for a
  live session regardless of when it was created.
- Slash-command config surfaces; deep model catalog editing (pi `models.json`).
- Any layout/tabs work (SPEC-desktop-workspace-tabs).
