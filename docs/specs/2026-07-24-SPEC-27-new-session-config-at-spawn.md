# SPEC-27 — New-session configuration at spawn (worktree · harness · config options)

**Status:** Proposed · **Priority:** P2 · **Surface:** desktop chat starter (`app/lib/desktop/chat/`), server (`server/src/`), wire protocol
**Depends on:** SPEC-26 (unified `configOptions` model + composer renderer this dialog reuses), SPEC-10 (desktop chat app). **Supersedes** SPEC-05's spawn path (session-in-pane) — all sessions are headless (no attachable pane).
**Prerequisite / assumption:** **Two transports, one config model.** pi runs
**over ACP** via the standalone **`pi-acp`** adapter (the native pi adapter
`server/src/adapters/pi.ts` is **removed**; `pi-acp` is the ACP server — pi does
not ship an ACP mode). codex runs on **`codex app-server`** (`codex-native`,
`CodexAppServerAdapter`) — **kept**, not retired — with its config surface
**projected** into the same `SessionConfigOption` model (SPEC-26). So the
`native` transport stays for codex; the descriptor `transport` is `"acp"` or
`"native"`. (`codex-acp` is the ACP target for codex — not yet implemented; when
it ships codex moves to the ACP path with no client/wire change.)
**Availability gate:** pi is listed only when the `pi-acp` binary resolves; codex
when `codex app-server` resolves. *This spec introduces the cached capability
catalog on `agents.list` + `agents.refresh` and the `session.spawn` config
picks (applied at launch).*

---

## Problem

Creating a new session today lets the user choose only the **worktree**
(implicit from context) and the **harness/agent** (the `WorktreeStartView`
picker). A harness's configuration — **model, reasoning level, mode,** and other
options — cannot be chosen up front:

- `session.spawn` carries no config; a session starts on the harness **default**
  and the user only adjusts *after* the first message via the per-session
  composer selectors (`app/lib/ui/composer/composer_selectors.dart`).
- A harness's options arrive **only after a session exists** — ACP returns
  `configOptions` in the `session/new` response (SPEC-26). There is nothing to
  pick from before a session, so the config can't be set at spawn today.

Users want to decide **which worktree, which harness, and its config** (model /
reasoning / mode / …) *before* the session starts — in a dedicated **New session
dialog** (decision 1).

## Goal

The **New session dialog** configures a new session up front:

1. **Worktree** — which worktree the session runs in.
2. **Harness** — which agent (pi via ACP, codex via app-server).
3. **Config options** — the harness's `configOptions` (categories `model` /
   `thought_level` / `model_config` / `mode` / boolean), read from a **cached
   catalog** so they can be shown with no live session.

The chosen options are **applied at launch** — ACP via
`session/set_config_option`, codex via its thread/turn params — so the
session's first turn already runs with them. Omitting any option falls back
to the harness default — **backward compatible**.

---

## Decisions (frozen)

1. **Config lives in a dedicated "New session" dialog.** A single modal
   (evolved from `new_session_dialog.dart`) configures worktree, harness, and
   the config options, then creates the session; the split just shows chat once it
   exists. This dialog is the **one entry point** for a new session and
   **replaces both** today's `WorktreeStartView` (inline "start in an existing
   worktree") and the old worktree-only `new_session_dialog` ("new worktree from
   branch/PR"). SPEC-28's inline starter Tab is removed (see SPEC-28 update).
2. **Worktree selection merges the two flows into one field.** A single
   **Worktree** control with a source toggle:
   - **Existing** — land the session on an existing worktree (list/search;
     defaults to the active tab's worktree, else the repo default).
   - **New branch** — fork a fresh worktree off a chosen base branch (today's
     Branch tab).
   - **From PR** — fork a worktree on an open PR's head branch (today's PR tab).
   This unifies "start a session from an existing worktree" and "new session in
   a new worktree" behind one picker. The worktree is created **lazily on send**
   — discovery reads from the cached catalog (decision 4/5) and needs no `cwd`,
   so nothing is materialized while the dialog is open.
3. **Config = the harness's unified `configOptions`.** Every harness exposes a
   list of `configOptions` (categories `model` / `thought_level` /
   `model_config` / `mode`, plus booleans) — ACP harnesses (pi via `pi-acp`)
   emit them natively; codex's `app-server` surface is **projected** into the
   same shape (SPEC-26). There is **no** separate native model/thinking model
   in the dialog. Options can be **dependent** (e.g. choosing a `model` changes
   the available `thought_level`s): the dialog renders from the cached snapshot
   and does not recompute dependencies; the **live session's `configOptions` is
   authoritative** and reconciles at launch (a pre-spawn pick is a *request*).

> **UX mockup:** `mockups/new-session-dialog.html` — chosen design is the
> **"Harness cards — model/reasoning as borderless buttons in the composer"**
> variant (✕ header = cancel; composer ↑ = start).
4. **Config comes from a cached catalog — no eager session (frozen).** A
   harness's `configOptions` are known only once a session/thread exists (ACP:
   the `session/new` response; codex `app-server`: from its model/config
   surface). Rather than open a live session while the dialog is up, makit keeps
   a **cached catalog** of each harness's `configOptions` (decision 5),
   populated by a **one-time throwaway probe** whose mechanism is per transport:
   **ACP** → `session/new` in an empty temp `cwd`, options captured, session
   killed; **codex `app-server`** → query its model/reasoning surface (no user
   thread retained). The dialog **reads the catalog from cache** — no live
   session, no worktree, no teardown races — and renders it via SPEC-26's
   generic renderer. Picks are held as **pending config** and **applied at
   launch**: on send, makit creates the worktree, starts the real session, and
   applies each pick — **ACP** via `session/set_config_option`, **codex** via
   its `thread/start`/`turn/start` params — then sends the first prompt. There
   is **no** `session.prepare/commit/cancel` control plane.
5. **One cached catalog per harness, keyed by a fingerprint.** Each harness's
   `configOptions` are cached in a small store and read on every "new session"
   with no live session. Populated by the throwaway probe (decision 4).
   **Fingerprint** = hash of the resolved **binary (path + version/mtime)** plus
   the harness's config inputs that change its catalog — for pi (`pi-acp`),
   `~/.pi/agent/models.json` + provider auth state; for codex, its model config
   / auth; for other agents, their own config/env. A pure binary checksum is insufficient (editing `models.json`
   or logging in a provider changes the catalog without changing the binary).
   Cache miss / fingerprint change → re-probe once; also expose a manual
   **refresh**. A harness that advertises no options → the dialog shows no config
   pickers (default-only). **cwd caveat:** the single empty-`cwd` catalog is
   correct only for harnesses whose options are **cwd-independent**; a harness
   that derives options from repo-local config must either be excluded from this
   fast path (probed per worktree) or have those workspace inputs folded into
   the fingerprint.
6. **Applied at launch, best-effort.** The chosen `configOptions` picks are
   carried on the draft and applied when the agent launches on the first
   message, after the session/thread starts and before the first prompt — ACP
   via `session/set_config_option`, codex via its `thread/start`/`turn/start`
   params. An adapter that cannot honour a pick ignores it; the live session's
   reported `configOptions` is the source of truth.
7. **Defaults / omission = harness default.** `session.spawn` without
   `configOptions` picks starts the harness on its own defaults. This spec only
   *adds* optional picks.
8. **No cross-session memory in this spec.** The starter does not remember the
   last-used model/reasoning; it shows the harness defaults. (Per-harness
   last-used memory is a possible follow-up — out of scope.)

---

## Current-state anchors (real code this reshapes)

> **Removed by this spec:** the native pi adapter (`server/src/adapters/pi.ts`)
> and pi's **mux-pane** path (`manager.spawnPiSessionInPane`, SPEC-05). pi now
> runs headless via **`pi-acp`** through the existing `AcpAdapter`. **`codex`
> (`app-server`, `CodexAppServerAdapter`) is kept** — the `native` transport
> stays for it; only pi's native adapter goes. `catalog.ts` lists pi (acp) +
> codex (native). This reintroduces `pi-acp` (removed in PR #25 for ACP
> file-access reasons; that concern is **accepted / out of scope** here — no
> additional fs sandboxing is planned).

- **Flutter**
  - `app/lib/desktop/chat/harness_picker.dart` — `WorktreeStartView` (removed;
    replaced by the dialog) and `HarnessPicker`; `desktop_chat_pane.dart` — the
    sessionless-pane fallbacks (`WorktreeStartView` branch + button-less
    `_NoSelection`), unified into the placeholder; `keymap_scope.dart` /
    `selected_session.dart` — `ShortcutAction.newPane` → opens the dialog.
  - `app/lib/ui/composer/composer_selectors.dart` — the composer's config
    selectors; SPEC-26 unifies these into one `configOptions` renderer this
    dialog reuses.
  - `app/lib/ui/home/new_session_sheet.dart` — mobile bottom sheet
    (`NewSessionChoice`); `repo_card.dart` — calls it and `spawnSession`.
  - `app/lib/store/store.dart` — `spawnSession(projectId, {agent, worktreePath,
    branch, …})`, `fetchAgents()`.
  - `app/lib/store/models.dart` — `AgentDescriptor`, `SessionMeta`,
    `SessionConfigOption` (SPEC-26).
- **Server / protocol**
  - `server/src/adapters/catalog.ts` — `listAgents()`/`transportFor()` (drop
    native pi; pi → `acp` via `pi-acp`; keep codex → `native` via `app-server`).
  - `server/src/adapters/acp.ts` — the ACP adapter pi runs through; the ACP
    probe + `set_config_option` live here. `server/src/adapters/codex.ts` —
    `CodexAppServerAdapter`; its config **projection** + probe live here
    (SPEC-26).
  - `server/src/ws/commands/session.ts` — `session.spawn` handler, `agents.list`.
  - `server/src/manager.ts` — `spawnPendingSession(...)`; the pi mux-pane path
    is removed (all sessions headless).
  - `server/src/protocol.ts` — command-kind union, `SessionSpec`/draft types.

---

## Target model

### Protocol (`server/src/protocol.ts`)

Extend the agent descriptor with a **cached capability catalog**, and
`session.spawn` with the config picks. **No `session.prepare` control plane.**

```ts
// agents.list → each descriptor (catalog served from cache):
interface AgentDescriptor {
  id: string; label: string; available: boolean;
  transport: "acp" | "native";   // pi=acp (pi-acp), codex=native (app-server)
  fingerprint: string;           // hash of binary version + config inputs (models.json, auth, ...)

  // Cached configOptions snapshot from the throwaway probe (ACP: session/new;
  // codex: app-server surface projection). SPEC-26 shape:
  // {id, name, category, type, currentValue, options?/groups?}. Rendered by
  // SPEC-26's generic renderer; picks applied at launch. Absent/empty → default-only.
  configOptions?: SessionConfigOption[];
}

// agents.refresh { agent }  → re-probe this harness and update the cached
//   catalog (also auto-triggered when the fingerprint changes). Returns the
//   fresh AgentDescriptor.

// session.spawn env — NEW optional field (applied at launch):
//   configOptions?: { id: string; value: string | boolean }[]   (picks;
//   `id` = SessionConfigOption.id — the server maps it to ACP
//   session/set_config_option's `configId` param, or to codex app-server's
//   thread/turn params)
```

### Server (`session.ts` handler, `manager.ts`, `catalog.ts`, `acp.ts`, `codex.ts`)

- **Capability cache.** A store (SQLite/JSON under the makit data dir) keyed by
  `agentId → { fingerprint, configOptions? }`. `agents.list` serves from cache;
  on a fingerprint miss/change it re-probes that harness (once) before
  returning. `agents.refresh { agent }` forces a re-probe.
- **Fingerprint.** `catalog.ts` computes it from the resolved binary
  (path + `--version`/mtime) **plus** the harness's catalog-affecting config:
  for pi (`pi-acp`), `~/.pi/agent/models.json` + provider auth/login state; for
  codex, its model config / auth; for another agent, its own config/env. Not a
  bare binary checksum.
- **Probe (only on miss/refresh), per transport.** **ACP** (pi): launch the
  adapter, run `initialize` + `session/new` in an **empty temp `cwd`**, capture
  the returned `configOptions`, then **clean up** — invoke the agent's
  session-cleanup RPC if it offers one (ACP v1 has no standard
  `session/close`/delete), then **kill** + dispose. A successful `session/new`
  may write persistent session state (e.g. `pi-acp` files); `kill()` alone can
  orphan it, so probes MUST use a throwaway temp `cwd` + best-effort cleanup.
  **codex `app-server`:** query the model/reasoning surface (no user thread
  retained) and **project** it into `configOptions` (SPEC-26). **cwd caveat:**
  the single empty-`cwd` catalog is valid only for harnesses whose
  `configOptions` are **cwd-independent**; a harness that derives options from
  repo-local config/extensions must either be excluded from the fast path
  (probe per worktree) or fold the workspace inputs into the fingerprint
  (decision 5).
- **`session.spawn` (apply at launch).** Reads optional `configOptions` picks,
  validates against the cached catalog (ignore/clear on mismatch), carries them
  on the draft. On first-message launch, after the real session/thread starts
  (in the user's worktree) and before the first prompt, apply each pick — ACP
  via `session/set_config_option`, codex via `thread/start`/`turn/start`
  params; the live session's returned `configOptions` is authoritative
  (reconciles dependent options). A pick a harness can't honour is ignored.
  There is **no** prepare/commit/cancel control plane, **no** eager
  session/worktree, and **no** mux-pane path.

### Flutter (`store.dart`, `new_session_dialog.dart`, `models.dart`)

- `AgentDescriptor` gains `configOptions` + `fingerprint` parsing from
  `agents.list` (served from the server cache).
- `spawnSession` gains an optional `configOptions` picks field, forwarded in the
  `session.spawn` env.
- The **New session dialog** (evolved `new_session_dialog.dart`) is laid out
  top-to-bottom (see `mockups/new-session-dialog.html`, the **"Harness cards —
  model/reasoning as borderless buttons"** variant — the chosen design):
  1. **Header** — title “New session” + an **✕ close** button (this is Cancel;
     there is no footer button row).
  2. **Worktree** field with the `Existing · New branch · From PR` source toggle
     (decision 2) and the matching selector below.
  3. **Harness** as a grid of selectable **cards** (icon, name, transport;
     selected = accent ring + check; unavailable dimmed) — reusing the existing
     `_HarnessCard` look.
  4. **First message** composer (reusing `Composer`). The harness's config
     selectors sit *inside* the composer as **borderless buttons** above the
     input (the existing `_ComposerPill` + `ThinkingSignal` visuals), rendered
     from the cached `configOptions` catalog via **SPEC-26's generic category
     renderer** (model / thought_level / model_config / mode / boolean) — **no
     live session**.
  - Selecting a harness swaps the buttons to that harness's cached
    `configOptions`. Picks are held locally as **pending config**. The
    composer's **send** (↑ / ⏎) is the single start action: it resolves/creates
    the worktree (existing → land; new branch → `createWorktree`; PR →
    `createWorktreeFromPr`), then `spawnSession(projectId, agent, worktreePath,
    configOptions: picks)`. The server applies the picks at launch (decision 6).
    It then opens/selects the created session in the active chat surface (a
    **Tab in the active split** once SPEC-28 lands; today's selected pane before
    that) and closes the dialog. **✕/Escape** just closes — nothing was created
    to tear down. `WorktreeStartView` and the worktree-only `new_session_dialog`
    are removed.

  **Every empty pane reaches this dialog (interim, until SPEC-28's starter
  Tab formalizes it).** All sessionless pane states — today split across
  `WorktreeStartView` and the button-less `_NoSelection` — render **one**
  placeholder ("Select a session, or start a new one") with a **New session**
  button opening this dialog, the Worktree field **pre-filled with the pane's
  worktree when known**:

  | Empty-pane source | Pre-fill |
  |---|---|
  | Fresh seed on worktree select (`_seed`) | that worktree |
  | Split (`splitActive` → new empty leaf) | the tree's worktree |
  | `ShortcutAction.newPane` ("New session in pane") | active worktree — and this action now **opens the dialog directly** (an empty pane whose only affordance is a button is a dead end for a keyboard action) |
  | Session quit/removed (`unbindSession`/`_clearSession`) | the tree's worktree |
  | Persisted layout → dead `sessionId` (resolve guard) | the tree's worktree |
  | Dead **draft** worktree (`draft:` prefix, nothing on disk) | none (worktree unset) |
  | Nothing selected (no current tree, `_NoSelection`) | none |

  The last two currently render `_NoSelection` **without any button** — they
  gain the same placeholder + New session button (no dead-end panes).

### Mobile (`ui/home/new_session_sheet.dart`, `repo_card.dart`)

Mobile keeps its **bottom-sheet** idiom (not the desktop dialog) and its
push-navigation flow (no tabs/splits — SPEC-28 is desktop/iPad-only). The sheet
gains the same configuration as desktop, stacked for a phone
(`mockups/new-session-mobile.html`):

- **Worktree** — add the `Existing · New branch · From PR` source toggle (today
  the sheet only forks a new branch), merging the two flows on mobile too.
- **Harness** — a horizontally scrollable row of the same harness **cards**.
- **Config options** — tappable rows rendering the harness's cached
  `configOptions` (model / thought_level / mode / …) via SPEC-26's renderer;
  picks held as pending config. Same cached catalog as desktop — no divergence.
- **Start** — unlike desktop, the composer is **not** folded into the sheet.
  `Start` spawns the draft with the chosen `agent` + `configOptions` picks, then
  the app lands on the full-screen session; the first message is typed there.
  The `NewSessionChoice` returned by the sheet grows a `configOptions` picks
  field, forwarded through `spawnSession`.

---

## Plan (TDD)

Server (`pnpm test`, `pnpm typecheck`):

1. **Capability cache + fingerprint.** `catalog.ts` computes the fingerprint
   (binary version + config inputs); the cache serves `agents.list` and
   re-probes on miss/change; `agents.refresh` forces it. Test: stable
   fingerprint → no re-probe; editing `models.json` / bumping the binary changes
   it → re-probe; refresh forces re-probe.
2. **Probe populates the catalog.** The throwaway probe captures `configOptions`
   (ACP: `session/new` in a temp `cwd`, then killed — no retained session/
   worktree; codex: project its model/reasoning surface). Test: catalog
   populated from a stub ACP adapter **and** from a stub codex `app-server`;
   a harness advertising no options yields an empty catalog.
3. **`session.spawn` applies picks at launch.** `configOptions` picks are
   validated against the cache, carried on the draft, and applied on
   first-message launch per transport — ACP via `session/set_config_option`
   after the real `session/new`, codex via `thread/start`/`turn/start` params —
   before the first prompt. Test that picks reach the real session (not the
   throwaway probe) on both transports and invalid picks are dropped.

Flutter (`flutter test --no-pub`, `flutter analyze --no-pub`):

4. **Descriptor parsing + `spawnSession` params.** Unit tests: `AgentDescriptor`
   parses `configOptions` + `fingerprint`; `spawnSession` forwards the picks.
5. **New session dialog UI (desktop/iPad).** Widget tests: the Worktree source
   toggle switches between Existing/New branch/From PR; the composer's borderless
   buttons render the cached `configOptions` (model/thought_level/mode/boolean)
   via the SPEC-26 renderer; switching harness swaps the buttons; **send** calls
   `spawnSession` with the picks; **✕/Escape** just closes (nothing created).
   **Empty-pane coverage:** every sessionless pane state (fresh seed, split,
   post-quit/unbind, dead persisted `sessionId`, dead `draft:` worktree, no
   selection) renders the placeholder with a **New session** button; the button
   opens the dialog pre-filled with the pane's worktree when known;
   `ShortcutAction.newPane` opens the dialog directly.
6. **Mobile new-session sheet.** Widget tests: `NewSessionSheet` shows the
   worktree source toggle + harness cards + cached `configOptions` rows;
   `NewSessionChoice` carries the picks and `repo_card.dart` forwards them to
   `spawnSession`.
7. **Green gate.** `flutter analyze --no-pub` clean; `flutter test --no-pub`
   green; `app/tool/audit.sh` passes; server `pnpm test` + `pnpm typecheck`
   green.

---

## Risks & notes

- **Reintroducing `pi-acp` (PR #25 context).** pi-acp was removed in #25 citing
  ACP file-access; **that concern is accepted here — no extra fs sandboxing is
  planned.** Running pi over ACP is the intended path.
- **codex is app-server, not ACP (stopgap).** codex's catalog is **projected**
  from `codex app-server` (model + reasoning-effort), not native ACP
  `configOptions`; its probe and apply-at-launch use the app-server thread/turn
  params, not `set_config_option`. `codex-acp` is the ACP target — when it
  exists codex moves to the ACP path with no client/wire change. Keep the
  transport branch (`acp`|`native`) small and confined to catalog/probe/apply.
- **Loss of the mux pane (SPEC-05).** pi no longer runs in an attachable
  terminal pane; all sessions are headless (pi via ACP, codex via app-server).
  SPEC-05's pi-in-pane path and the README “attach to the pane” story are
  **retired** — update/close SPEC-05 accordingly.
- **Cache staleness.** The catalog is a snapshot; the true set can change (new
  provider login, edited `models.json`, harness update). The fingerprint must
  cover those inputs, with a manual **refresh** escape hatch. A pre-spawn pick
  is a **request**; the live session's `configOptions` is authoritative.
- **Dependent options render from cached defaults.** ACP options can be
  dependent (model → available reasoning). The cache holds the initial tree; the
  dialog does not recompute (no live session). The live session reconciles at
  launch. Only a harness with heavily dependent pre-launch options would need a
  live probe (out of scope).
- **Best-effort application.** Picks apply best-effort (an adapter may ignore an
  unsupported value); no hard failure.

## Out of scope

- **Per-harness last-used memory** for config picks — a later follow-up.
- Changing how config switches on an already-running session (the SPEC-26
  composer selectors are unchanged).
- Formally retiring SPEC-05's mux-pane path is a consequence tracked here;
  ACP fs sandboxing is **explicitly not planned** (accepted).
- **Mobile:** the tab/split layer (SPEC-28) does not apply; mobile keeps
  push-navigation and one session per screen (it does gain the merged worktree
  flow + cached config in its sheet).
