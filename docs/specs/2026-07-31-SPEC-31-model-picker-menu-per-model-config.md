# SPEC-31 — Model picker menu + per-model config flyout

**Status:** Proposed · **Priority:** P2 · **Surface:** desktop + mobile composer selectors (`app/lib/ui/composer/`), new-session dialog (`app/lib/desktop/chat/worktree_starter.dart`), a client-side recent/prefs store (`app/lib/store/`, `shared_preferences`)
**Depends on:** SPEC-26 (ACP config options + unified composer), SPEC-27 (new-session config at spawn). Reuses the existing `SessionConfigOption` wire model and the `configOption` session action **unchanged** — v1 (option C below) is a presentation + recent-list-persistence spec, **no server or protocol change**. Cross-session per-model config (option B) is deferred as a follow-up that *does* need server work.

---

## Problem

The composer renders every `SessionConfigOption` as a **flat, co-equal pill**
(`ConfigOptionPickRow` → one `ConfigOptionPill` per option, in agent order).
That has three problems now that agents emit rich option sets:

1. **Wrong mental model.** Reasoning (`thought_level`), context size and
   speed/quality (`model_config`) are *attributes of the chosen model* — their
   valid values change per model — yet they sit beside the model as siblings,
   competing for footer width. The footer is already known to be cramped in
   split panes (see the width note in `composer_selectors.dart` `ThinkingSignal`).
2. **The model list does not scale.** The `model` category can carry **~300**
   choices. The current searchable sheet handles hunting but offers no notion of
   the handful of models a user actually cycles between, and no per-model tuning.
3. **No per-model config.** Reasoning/context/fast can only be set for the *live*
   active model and are forgotten on switch. A user who runs GPT-5 at `high` and
   Sonnet at `medium` must re-tune on every switch.

## Goal

Reorganise the model + model-scoped config into a **single model picker menu**,
without changing the wire model:

- **Footer:** the `model` pill carries **faint, read-only chips** summarising the
  active model's config (reasoning signal-bar · context · fast). The standalone
  `thought_level` pill is **removed** — it becomes a label under the model.
  `mode` and unknown categories **remain separate pills** (they are
  session-scoped, not model-scoped).
- **Menu (opened from the model pill):** a **search-driven** panel. Empty query
  shows **Recent** models (last-used, capped) each with a **config flyout**;
  typing filters the **full catalog** (selection only, no config).
- **Flyout:** a **narrow vertical column** of subtle segments — one per
  model-scoped option (`thought_level`, each `model_config`) — values stacked
  top-to-bottom, current value marked. Booleans render as a single toggle row.
  Same column on desktop (beside the row) and mobile (pushed as a second sheet
  page).
- **Per-model config** is tuned live for the **active** model via the flyout; the
  **recent-model list** is remembered client-side. (Cross-session per-model
  config memory — option B — is a deferred follow-up; see the design decision.)

Mock: `mockups/model-picker.html` (approved).

---

## Current-state anchors (real code this reshapes)

- `app/lib/ui/composer/composer_selectors.dart` — `ConfigOptionPickRow`,
  `ConfigOptionPill` (SPEC-27), `ComposerConfigOptions`, `ThinkingSignal`, and
  the legacy `ComposerModelSelector`/`ComposerThinkingSelector`/`ComposerModeSelector`.
- `app/lib/store/models.dart` — `SessionConfigOption` (id, name, description,
  `category`, `type` select/boolean, `currentValue`, `options`, `groups`),
  `ConfigOptionValue`, `ConfigOptionGroup`, `ConfigOptionType`.
- `app/lib/ui/widgets/searchable_list_sheet.dart` — `showSearchableListSheet`
  (reused for the typing/hunt state).
- `app/lib/desktop/chat/worktree_starter.dart` — pre-session `ConfigOptionPickRow`.
- `app/lib/desktop/settings/prefs/preferences_controller.dart` — the house
  pattern for a `shared_preferences`-backed, diff-only, JSON-encoded store
  (model to mirror for the recent/prefs store).
- `app/lib/ui/session/session_screen.dart` & `app/lib/desktop/chat/desktop_chat_pane.dart`
  — the two composer footer call sites (`ComposerConfigOptions` else legacy triple).
- Store action path: `storeControllerProvider.sendSessionAction(sessionId,
  'configOption', {id, value})` → server maps to ACP `session/set_config_option`
  (`server/src/adapters/acp.ts`), which re-emits the **complete** option list.

**Not touched:** `server/`, `protocol.ts`, the `configOption` action, the
`SessionConfigOption` wire shape. All logic is app-side.

---

## Category grouping (Makit UX policy — NOT ACP semantics)

ACP `category` is an **open, UX-only hint**; the server forwards it unchanged
(`models.dart:282`, `acp.ts` passthrough) and does **not** guarantee any category
is model-scoped (`thought_level` is notably a *next-turn* setting for codex). The
grouping below is therefore **Makit presentation policy**, applied conservatively:
unknown/ambiguous categories always stay standalone so we never mis-fold an
option. Options partition into two buckets by `category`:

| Bucket | Categories | Rendering |
|---|---|---|
| **Model-scoped** | `model`, `model_config`, `thought_level` | Folded into the model picker: `model` = the list; `model_config` + `thought_level` = flyout segments. |
| **Standalone** | `mode`, unknown/`_`-prefixed, any non-model-scoped | Rendered as their own pill exactly as today (`ConfigOptionPill`), after the model pill. |

If a session advertises **no** `model` category option, the whole model-picker
path is skipped and every option renders as today (full back-compat: native/legacy
sessions, agents without a model selector).

---

## Target UX

### Footer
```
[◈ GPT-5  ▁▃▅▆·(hi)  256k  fast]   [⚙ code]
 └ model pill: avatar + name + faint read-only chips   └ mode (separate pill)
```
- Chips are **labels, not buttons**: reasoning = the existing `ThinkingSignal`
  bars; each remaining `model_config` = its current value (`256k`; boolean shown
  only when true, e.g. `fast`). Tapping anywhere on the pill opens the menu.
- Chips render only for options that exist for the active model; nothing when the
  model has no model-scoped config.

### Menu (tap model pill)
- **Search field** at top.
- **Empty query → Recent:** up to `kRecentModelsMax` (7) last-used models for
  this agent, each row: avatar + name + faint chips + `✓` (if active). Only the
  **active** model's row shows the `›` flyout affordance and is expandable;
  non-active rows are **select-only** (tapping selects, which then makes that
  row active and reveals its flyout). Below, a `Browse all models · N` row (or the
  list simply continues).
- **Non-empty query → Results:** flat filtered list across the **full** `model`
  option catalog (`options` + flattened `groups`), selection only — **no chips,
  no flyout**. Selecting a non-recent model promotes it into Recent.
- Reuses `showSearchableListSheet` semantics on mobile; desktop uses a
  `MenuAnchor`/overlay panel of the same content.

### Flyout (active model only)
- Shown only for the **active** model's row (v1/C: non-active rows are
  select-only). Narrow vertical column. One **segment per model-scoped sub-option**, in agent
  order, header = option name (reasoning header carries the `ThinkingSignal`
  glyph). `select` → values stacked vertically, current marked (`✓` + accent).
  `boolean` → one toggle row.
- Desktop: anchored beside the row. Mobile: pushed as a second sheet page with a
  `‹` back affordance. **Same widget, two containers.**

---

## Key design decision — how per-model config is applied

The live ACP session has exactly **one** active model and one config-option list
(the active model's). Offering config for a *non-active* recent model requires
client-side shadow state and a re-apply step. Crucially — per the codex review —
that re-apply is **not** app-only: `sendSessionAction` is fire-and-forget and the
server ACKs **before** the adapter applies (`store.dart:444`, `session.ts:88`), so
the app has no completion barrier to "send model → wait for re-emit → validate →
send sub-options." Listening for the next `session.meta` races autonomous updates
and competing user picks. Three readings:

- **(A) Active-model-only.** Flyout interactive only for the active model; other
  recent rows select-only. No persistence. Loses cross-model/-session memory.
- **(B) Per-recent-model remembered config.** Store `agent → model → {optionId:
  value}` and re-apply on select. **Requires server support** — a serialized,
  atomic "apply model + config" command (or request/result correlation with
  generation/cancellation), because the current fire-and-forget action gives no
  barrier and no rejection/timeout signal. This is a wire/server change; it is
  **not** in the app-only scope this spec targets.
- **(C) Recents + active-model tuning (chosen v1).** Ship the full menu + flyout
  + recents. Persist **only the recent-model list** (app-only, safe). The flyout
  tunes the **active** model live via the existing `configOption` action;
  selecting a different recent model leaves its agent-defined `currentValue`
  intact and the user tunes after selecting. No per-model shadow state, no
  apply-on-select sequencing, no server change.

**This spec targets (C).** It delivers the entire approved UX (footer chips,
search-driven menu, Recent, vertical flyout) with zero server work and no
speculative shadow state. (B) is documented as a **follow-up** requiring a server
orchestration contract and is explicitly out of scope here.

---

## Client store (v1 — recent list only)

A `shared_preferences`-backed store mirroring `PreferencesController`'s
single-JSON-key philosophy, holding **only** the recent-model list:

- Per agent, an ordered list of recently selected model **values**,
  most-recent-first, deduped, capped at `kRecentModelsMax`. Updated on every
  successful model select.
- Keyed by **agent id** (model values differ per harness). No cross-agent share.
- Corrupt/absent JSON → empty list (tolerant, mirrors `PreferencesController`).

Riverpod provider exposing `recentModels(agent)`; controller with `recordSelect`.
No per-model sub-option persistence in v1 (that is follow-up B).

---

## Plan (TDD) — app only

`flutter test --no-pub`, `flutter analyze --no-pub`, `app/tool/audit.sh`.

1. **Category partition + footer chips.** Pure function splitting `configOptions`
   into model-scoped vs standalone (conservative: unknowns stay standalone).
   `ComposerConfigOptions` renders: model pill (with read-only chips derived from
   the active model's model-scoped set) + standalone pills. No `model` option →
   renders exactly as today. Widget tests: chip content (reasoning bars,
   `model_config` current values, boolean-when-true); mode stays a separate pill;
   back-compat path unchanged.
2. **Recent store.** `shared_preferences`-backed controller + provider: recent
   list capping/dedup/order; corrupt-JSON tolerance; agent-scoping. Unit tests
   mirroring `preferences_controller` tests.
3. **Menu — search states.** `ModelPickerMenu`: empty → Recent rows (chips, `✓`,
   `›`); typing → flat filtered full catalog (selection only); select promotes to
   Recent + dispatches the `model` `configOption`. Widget tests for both states,
   group-flattening, and the empty-catalog skip.
4. **Flyout (active model).** Narrow vertical segment column from the active
   model's model-scoped options: select segments (values vertical, current
   marked), boolean toggle row, agent-order. Each change dispatches the existing
   `configOption` action; the composer re-renders from the re-emitted list (never
   merges). Non-active recent rows are select-only. Widget tests: renders per
   option; change dispatches `configOption`; re-emit re-renders; option
   disappearing after a set does not crash.
5. **New-session dialog parity.** `worktree_starter.dart` uses the same menu/flyout
   for the pre-session draft (local pending picks, no live session), reusing the
   existing `ConfigOptionPickRow` seam. Draft picks apply at launch (no live
   re-emit barrier) — unchanged from SPEC-27.
6. **Green gate.** `flutter analyze --no-pub` clean; `flutter test --no-pub`
   green; `app/tool/audit.sh` passes. Server untouched.

---

## Risks & notes

- **Fire-and-forget actions (why B is deferred).** `sendSessionAction` gets no
  correlated result and the server ACKs before the adapter applies; there is no
  barrier/rejection/timeout signal to sequence a multi-step apply on. v1 (C)
  sidesteps this by only ever setting the **active** model's options one at a
  time and re-rendering from the re-emitted list.
- **Re-emit is a full replacement.** Every `configOption` set re-emits the
  complete list and may add/remove later options; the composer must re-render
  wholly from it (never merge) — already the SPEC-26/27 contract. An option that
  disappears after a set must not crash the flyout.
- **Footer width.** Chips must stay compact and ellipsis/clip gracefully in
  narrow split panes (the existing `ThinkingSignal` width contract applies).
- **Desktop vs mobile presentation fork.** One flyout widget, two hosts
  (`MenuAnchor` overlay vs pushed sheet page); identical column layout.
- **Recent noise.** Recent is last-used auto-managed (no pinning) — YAGNI.
- **Back-compat.** Sessions without a `model` category option, and the legacy
  `model/thinking/modes` `SessionMeta` fallback, render exactly as today.

## Out of scope

- **(B) per-recent-model remembered config** — requires a server-side atomic
  "apply model + config" command (or request/result correlation); deferred to a
  follow-up spec.
- Any server/protocol/wire change; the `configOption` action and
  `SessionConfigOption` shape are reused as-is.
- Pinning/reordering Recent; per-model config editing beyond the active-model
  flyout.
- Deep model-catalog editing (pi `models.json`), slash-command config surfaces.
- Changing `mode` or unknown-category rendering (they stay standalone pills).
