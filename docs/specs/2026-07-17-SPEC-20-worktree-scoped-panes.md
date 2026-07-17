# SPEC-20 — Worktree-scoped pane layouts

**Status:** Proposed · **Priority:** P2 · **Surface:** desktop chat (`app/lib/desktop/chat/`)
**Depends on:** SPEC-05 (session-in-pane spawning), SPEC-10 (desktop chat app), SPEC-19 (pane decomposition — the files this reshapes)

---

## Problem

The desktop chat surface has **one global split-pane tree**. Selecting a
worktree in the sidebar only re-binds the **active** pane to that worktree, so
splitting into four panes and then clicking a worktree changes just one of the
four. There is no notion of a worktree "owning" a layout.

Users think per-worktree: *this* worktree has this arrangement of panes and
sessions; *that* worktree has a different one. Switching worktrees should swap
the **entire** pane view, not mutate one pane inside a shared layout.

## Goal

Invert the ownership: **the worktree owns the pane tree.** Each worktree has its
own layout — which panes are open, their split axes and ratios, which session
each pane hosts, and the active pane. Selecting a worktree swaps the whole view
to that worktree's saved layout. Layouts persist across app restarts.

---

## Decisions (frozen)

These resolve the open questions for this spec:

1. **No worktree selected → empty placeholder.** On fresh launch or after the
   selection is cleared, the pane area shows the existing "Select or start a
   session" empty state. There is **no** default/global tree; per-worktree
   trees exist only once a worktree is chosen.
2. **First selection seeds one empty starter pane.** The first time a worktree
   is selected (no saved layout), its tree is a single empty leaf that renders
   the `WorktreeStartView` harness picker for that worktree. Sessions/splits are
   added by the user from there.
3. **Layouts persist across app restarts.** Each worktree's tree is serialized
   to `SharedPreferences` as JSON, following the `PreferencesController` pattern
   (nullable prefs → ephemeral in tests; `.load()` factory; diff-free full
   dump). Switching worktrees within a session and full restarts both preserve
   layouts.
4. **Sidebar session selection follows the session's own worktree.** Selecting a
   session that belongs to worktree *B* while viewing worktree *A* switches the
   whole view to *B*'s tree (seeding it if absent), then binds the session into
   *B*'s active pane. Selection never mixes sessions from different worktrees
   into one layout.

---

## Current-state anchors (real code this reshapes)

- `app/lib/desktop/chat/panes/pane_node.dart` — immutable `PaneNode`
  (`PaneLeaf {id, sessionId?, worktree?}` / `PaneSplit`), pure tree functions
  (`splitLeaf`, `closeLeaf`, `setRatio`, `moveLeaf`, `mapLeaves`, …).
- `app/lib/desktop/chat/panes/pane_tree_controller.dart` — single
  `StateNotifier<PaneTreeState>` (`{root, activeLeafId}`); ops target the active
  leaf; `bindActiveWorktree` pins a worktree to **one** leaf (the current bug).
- `app/lib/desktop/chat/selected_session.dart` /
  `selected_worktree.dart` — `selectedSessionProvider`,
  `selectedWorktreeProvider`, `selectSessionExclusive`, `selectWorktree`.
- `app/lib/desktop/chat/panes/pane_tree_view.dart` — renders the single tree;
  each `_PaneLeafView` passes `leaf.worktree` into `DesktopChatPane`.
- `app/lib/desktop/chat/desktop_chat_pane.dart` — `worktree` + `sessionId` +
  `trackGlobalSelection` params; renders `WorktreeStartView` for a
  sessionless-worktree leaf.
- `app/lib/desktop/chat/keymap_scope.dart` — `_splitPane` reads/pins per-leaf
  worktree + global selection.
- `app/lib/desktop/chat/desktop_sidebar.dart` (`_WorktreeGroup`),
  `new_session_dialog.dart` — call `selectWorktree`.
- `app/lib/desktop/desktop_app.dart` — `.load()` wiring for
  `KeymapController` / `PreferencesController` (the persistence template).
- `app/test/desktop/chat/pane_tree_view_test.dart` — widget tests that assume
  the single-tree model and per-leaf worktree binding.

---

## Target model

### Node (`pane_node.dart`)

`PaneLeaf` **drops** its `worktree` field:

```dart
final class PaneLeaf extends PaneNode {
  const PaneLeaf({required this.id, this.sessionId});
  final String id;
  final String? sessionId; // null → "start a session in this tree's worktree"
}
```

A null-`sessionId` leaf now means *"start a session in the tree's worktree"* —
the worktree comes from the enclosing tree, not the leaf. `PaneLeaf.worktree`,
`bindActiveWorktree`, and the "pinned worktree" plumbing are removed.

Add JSON: `PaneNode.toJson()` / `PaneNode.fromJson()` (leaf = `{k:'leaf', id,
sessionId}`; split = `{k:'split', id, axis, ratio, first, second}`).

### Tree (`pane_tree_controller.dart`)

`PaneTreeState` **gains** the worktree it belongs to:

```dart
class PaneTreeState {
  const PaneTreeState({required this.root, required this.activeLeafId, required this.worktree});
  final PaneNode root;
  final String activeLeafId;
  final SelectedWorktree worktree;
}
```

The controller state becomes a **workspace** of trees keyed by
`SelectedWorktree.path` (stable, unique per worktree):

```dart
class PaneWorkspaceState {
  final Map<String, PaneTreeState> trees; // key = worktree.path
  final String? currentKey;               // null → empty placeholder
  PaneTreeState? get current => currentKey == null ? null : trees[currentKey];
}
```

Controller API (all ops act on `current`; no-op when `current == null`):

| Method | Behaviour |
|---|---|
| `selectWorktree(SelectedWorktree wt)` | `currentKey = wt.path`; seed a single-empty-leaf tree bound to `wt` if absent. |
| `bindActiveSession(String id, SelectedWorktree wt)` | switch to `wt`'s tree (seed if absent), bind `id` to that tree's active leaf. Implements decision 4. |
| `clearSelection()` | `currentKey = null` (empty placeholder). |
| `splitActive(Axis)` / `closeActive()` / `setActive(id)` / `setRatio` / `adjustRatio` / `moveLeaf` | operate on `current`'s tree only. Split seeds a fresh empty leaf (no worktree param — the tree already knows its worktree). |
| `unbindSession(id)` | clear that session from every leaf **in every tree** (a quit session must not linger in any worktree's layout). |

Persistence: a `PaneWorkspacePrefs` (or `.load(prefs)` on the controller)
serializes `{trees: {path: treeJson}, currentKey}` under one
`SharedPreferences` key. Mirror `PreferencesController`: nullable prefs →
ephemeral (tests + provider default), write-through on every mutation.

### Selection providers (`selected_session.dart`)

- The controller owns the current worktree. `selectedWorktreeProvider` becomes a
  read synced from `current?.worktree` (kept for the sidebar highlight);
  `selectWorktree(ref, wt)` funnels through `paneTreeController.selectWorktree`.
- `selectSessionExclusive(ref, id)` resolves the session's worktree
  (`session.worktreePath/projectId/branch`) and calls
  `bindActiveSession(id, wt)`; `selectedSessionProvider` stays in sync for the
  sidebar highlight and mobile (mobile is unaffected — it does not use the pane
  tree).
- A session with **no** worktree (still-pending draft with no forked tree) keeps
  today's behaviour via the existing draft/linked-session path in `_splitPane`.

### View (`pane_tree_view.dart`, `desktop_chat_pane.dart`)

- `PaneTreeView` watches `current`. `null` → the `_NoSelection` placeholder.
  Non-null → render `current.root`, threading `current.worktree` down.
- `DesktopChatPane` **drops** the per-leaf `worktree` param. A leaf resolves its
  content as: bound `sessionId` → chat; else the tree's worktree →
  `WorktreeStartView`. `trackGlobalSelection` is no longer needed (there is no
  global fallback slot — the tree is the source of truth), so it and the
  global-worktree bleed-through guards are removed.

---

## Plan (TDD; verify each step with `flutter test --no-pub` + `flutter analyze --no-pub`)

1. **Model.** Drop `PaneLeaf.worktree`; add `PaneTreeState.worktree`; add
   `toJson`/`fromJson` for `PaneNode` + `PaneTreeState`. Unit tests: JSON
   round-trip for nested trees; leaf/split identity preserved.
2. **Controller.** Introduce `PaneWorkspaceState` (map + currentKey) and the
   per-worktree ops. Tests: select seeds one empty leaf; switching worktrees
   preserves each tree's layout/ratios/active leaf; `bindActiveSession` switches
   to the session's worktree; `clearSelection` → placeholder;
   `unbindSession` clears across all trees.
3. **Persistence.** `.load(prefs)` + write-through; ephemeral without prefs.
   Tests: mutate → reload from the same store → identical workspace; corrupt
   JSON → empty workspace. Wire `.load()` in `desktop_app.dart`.
4. **View + call sites.** Update `pane_tree_view.dart`, `desktop_chat_pane.dart`,
   `keymap_scope.dart` (`_splitPane` simplifies — no per-leaf worktree pinning),
   `desktop_sidebar.dart`, `new_session_dialog.dart`. Rewrite
   `pane_tree_view_test.dart` for the worktree-scoped model (a tree now requires
   a worktree; the "global fallback" and "sessionless-worktree split" groups are
   replaced by "switching worktrees swaps the view" + "empty placeholder when
   none selected").
5. **Green gate.** `flutter analyze --no-pub` clean; full `flutter test --no-pub`
   green; `app/tool/audit.sh` passes.

---

## Risks & notes

- **Churn in tests.** The existing pane tests encode the single-tree /
  per-leaf-worktree model; several are replaced, not tweaked. That is expected
  and intended — the model they guard is being removed.
- **`selectedWorktreeProvider` inversion.** It flips from a source of truth to a
  mirror of the controller's `currentKey`. Every writer must route through the
  controller; a stray direct `.state =` would desync the highlight from the
  view. Audit all writers (sidebar, new-session dialog, keymap_scope, tests).
- **Persistence of dead sessions.** A persisted tree may reference a session id
  that no longer exists after restart. A leaf whose `sessionId` resolves to no
  session falls back to the tree's `WorktreeStartView` (same as an empty leaf) —
  no crash, no dead pane. Covered by an `unbindSession`-style resolve-time guard.
- **Worktree key stability.** `path` is the key. A worktree whose path changes
  (rare; recreate) starts a fresh layout — acceptable.

## Out of scope

- Reordering/renaming worktrees, cross-worktree pane drag, or a worktree tab
  bar. Only the swap-on-select + per-worktree persistence behaviour is in scope.
- Mobile: unchanged (no pane tree there).
