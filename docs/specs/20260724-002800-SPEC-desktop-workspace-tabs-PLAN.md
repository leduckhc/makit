# SPEC-desktop-workspace-tabs — Execution plan

**Spec:** [20260724-002800-SPEC-desktop-workspace-tabs.md](20260724-002800-SPEC-desktop-workspace-tabs.md)
**Plan date:** 2026-07-24 · requires SPEC-new-session-config-at-spawn merged (New-session dialog exists;
`WorktreeStartView` already removed). Nothing of this spec is implemented yet.

## Current state (audit, not aspiration)

| Piece | File | State |
|---|---|---|
| Node model | `app/lib/desktop/chat/panes/pane_node.dart` | ❌ `PaneNode`/`PaneLeaf {id, sessionId?}`/`PaneSplit` — no tabs |
| Controller | `app/lib/desktop/chat/panes/pane_tree_controller.dart` | ❌ `PaneTreeState {root, activeLeafId, worktree}`; persistence under `kPaneWorkspacePrefsKey` |
| View | `pane_tree_view.dart`, `pane_header.dart` | ❌ one session per leaf; no tab bar |
| Selection | `selected_session.dart` / `selected_worktree.dart` | ❌ `closePane`, `newPaneInActiveWorktree`, worktree-swap semantics |
| Shortcuts | `app/lib/shortcuts/shortcut_action.dart`, `keymap_scope.dart` | ❌ `splitPaneVertical`/`splitPaneHorizontal`/"close pane" |
| iPad entry | `app/lib/main.dart` | ❌ `runDesktopApp()` gated on `Platform.isMacOS` only |
| Tests | `app/test/desktop/chat/pane_*` | ❌ encode single-session-per-leaf; rewritten, not tweaked |

## Lanes

```text
Lane 1 (node)        → pure Dart, no deps
Lane 2 (controller + persistence) → after Lane 1
Lane 3 (views + shortcuts + call sites) → after Lane 2
Lane 4 (iPad platform shell)      → parallel with Lanes 1–3 (owns main.dart only)
   └── all merge → Integration checkpoint
```

Lanes 1→2→3 are a serial chain (each consumes the previous layer's types);
Lane 4 is independent until the checkpoint. Every lane verifies with
`flutter analyze --no-pub` + `flutter test --no-pub` on its own files.

### Lane 1 — Node model (`split_node.dart`, renamed from `pane_node.dart`)
**Owns:** `panes/pane_node.dart` → `panes/split_node.dart` + its unit tests

- Rename `PaneNode`/`PaneLeaf`/`PaneSplit` → `SplitNode`/`Split`/`Splitter`;
  add `Tab {id, sessionId?, worktree?}`; `Split` holds `tabs` + `activeTabId`.
- Port pure functions (`divideSplit`, `removeSplit`, `setRatio`, `moveSplit`,
  `mapSplits`, `firstSplitWhere`, `containsSplit`) and add tab helpers
  (`addTab`, `removeTab`, `activateTab`, `reorderTab`, tree-wide `findTab`).
  Deterministic `nextNodeId()` (`split-N`/`splitter-N`/`tab-N`).
- Tests: JSON round-trip (nested trees, multi-tab splits, `worktree` on empty
  tabs only), identity preservation on divide/remove/move, `findTab`, tab
  ops, last-tab removal returns `null`.

### Lane 2 — Controller + persistence (`workspace_controller.dart`)
**Owns:** `panes/pane_tree_controller.dart` → `panes/workspace_controller.dart`
+ controller/persistence tests

- `WorkspaceState {root, activeSplitId}` — **one** workspace, no per-worktree
  map (SPEC-worktree-scoped-panes revert). Ops per the spec's controller table: `divideActive`,
  `closeActiveSplit`, `setActiveSplit`, ratio ops, `moveSplit`, `openTab`,
  `closeTab` (collapse / sole-split reset), `setActiveTab`, `moveTab`,
  `revealSession(sessionId)` (unique — decision 5), `unbindSession`.
- Persistence: `.load(prefs)` + write-through under `kWorkspacePrefsKey`
  (renamed); nullable prefs → ephemeral.
- Tests: divide seeds starter Tab; reveal focuses existing (no duplicate) else
  opens in active Split; emptied Split collapses, sole Split resets;
  `unbindSession`; cross-worktree tabs coexist; mutate → reload → identical;
  corrupt JSON → starter workspace; unresolvable persisted `sessionId` →
  placeholder, no crash.

### Lane 3 — Views, shortcuts, call sites
**Owns:** `panes/pane_tree_view.dart` → `split_tree_view.dart`(+`split_view.dart`),
`panes/pane_header.dart`, `desktop_chat_pane.dart`, `selected_session.dart`,
`selected_worktree.dart`, `keymap_scope.dart`, `shortcut_action.dart`,
`desktop_sidebar.dart`, `desktop_app.dart` (`.load()` wiring), widget tests

- `WorkspaceView` renders the tree; `Split` view = tab bar (active highlight,
  close/reorder, `+` → SPEC-new-session-config-at-spawn dialog) above the active Tab's
  `DesktopChatPane`; empty Tab → placeholder + New session button (pre-filled
  with `tab.worktree` when set).
- Drag/drop: Splits to `DropEdge` (`moveSplit`); Tabs within/between bars
  (`moveTab`).
- Selection: `selectSessionExclusive` → `revealSession(id)`;
  `selectedSessionProvider` mirrors the active Split's active Tab (audit all
  writers — no stray `.state =`); worktree "select" opens a starter Tab, never
  swaps layout.
- Shortcuts: `splitVertical`/`splitHorizontal`/`closeSplit` + `newTab`,
  `closeTab`, `nextTab`, `prevTab`; keep bindings, reword labels.
- Rewrite `pane_tree_view_test.dart` + selection tests for the Split/Tab model
  (reveal-in-place, tab switching, placeholder, cross-worktree coexistence).

### Lane 4 — iPad platform shell (decision 10)
**Owns:** `app/lib/main.dart` (+ a small size-class router widget) + its tests

- Route to the workspace shell on macOS **or** iPadOS with a regular×regular
  size class; mobile router on iPhone/compact (Stage-Manager compact iPad falls
  back to mobile).
- Tests: router picks workspace for regular×regular, mobile for compact;
  workspace providers initialize on the iPad path.

## Integration checkpoint (serial, after all lanes merge)

1. `cd app && flutter analyze --no-pub --fatal-infos` → zero issues.
2. Full `flutter test --no-pub` green; `app/tool/audit.sh` passes.
3. Manual smoke (macOS): split H/V; open several sessions from different
   worktrees as tabs in one view; sidebar click reveals the existing tab (no
   duplicate); drag a tab between splits; close last tab collapses the split;
   restart restores the exact layout; quit a session → its tab unbinds.
4. Manual smoke (iPad simulator or device, regular size class): workspace shell
   loads; rotation/Stage-Manager to compact falls back to the mobile router
   without losing state.

## Merge notes

- Lanes 1–3 land in order; a lane may merge only when its own tests are green
  (the tree stays compiling because renames complete within each lane).
- Lane 4 can land any time; before Lane 3 it simply routes iPad to the current
  pane UI.
- Expect the largest diff in Lane 3 — keep the pure-logic lanes (1–2) free of
  widget imports so their tests stay fast and deterministic.
