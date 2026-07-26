# SPEC-28 — Desktop/iPad workspace: recursive splits + tabs

**Status:** Proposed · **Priority:** P2 · **Surface:** desktop chat (`app/lib/desktop/chat/`)
**Depends on:** SPEC-10 (desktop chat app), SPEC-19 (pane decomposition — the files this reshapes), SPEC-27 (new-session dialog — the entry point that opens sessions as Tabs)
**Supersedes:** **SPEC-20 (worktree-scoped pane layouts)** — see "Relationship to SPEC-20" below.

---

## Problem

Two unrelated concepts are both called **"pane"**, which has caused persistent
confusion:

1. **Server execution slot** — `PaneInfo { mux, paneId }` (SPEC-05, now
   **retired**): the terminal-multiplexer slot where a session ran (e.g. tmux
   `%1`). Backend-only, not visual. *With SPEC-05/pi-over-ACP this concept is
   going away* — but the historical naming collision is why this spec is
   deliberate about vocabulary.
2. **Desktop UI split region** — `PaneNode`/`PaneLeaf`/`PaneSplit`
   (`app/lib/desktop/chat/panes/`): the recursive split layout. Ids like
   `pane-0`. Visual only.

`paneId` therefore means two different things depending on the file.

Separately, the desktop layout model is limiting. SPEC-20 tied one split tree to
one **worktree** (worktree owns the layout). A user cannot see **all** of their
work-in-progress in a single view: sessions from different worktrees/branches
can never appear together, because selecting a worktree swaps the whole layout.
There is also no notion of **tabs** — each split region hosts exactly one
session, so switching between sessions in a region is impossible without
splitting.

## Goal

A single, multitasking-first layout for **desktop and iPad**:

- **One workspace = one layout**, free-form and **worktree-agnostic**: its
  regions can host sessions from **any** worktree at once, so all
  work-in-progress is visible in one view.
- **Recursive splits** (grids), so many concurrent sessions stay legible.
- **Tabs inside each split**, so a region holds a strip of sessions and switches
  between them without re-splitting.
- **Clicking a session in the sidebar jumps to its tab** — focusing the split
  and tab that already host it (or opening a tab if none does).
- Retire the word **"pane"** from the UI entirely, so the server's **mux pane**
  no longer collides.

**Mobile is unchanged** — no workspace/split/tab layer; one session on screen
(the existing `session_screen.dart` push-navigation flow).

---

## Vocabulary (frozen naming)

| Term | Definition | Scope |
|---|---|---|
| **Workspace** | the single top-level **layout**; owns the recursive split tree. Free-form, worktree-agnostic. | desktop + iPad |
| **Splitter** | internal tree node: divides space along an [Axis] with a [ratio]; has exactly two children. | desktop + iPad |
| **Split** | leaf tree node: a region holding a **tab strip** (`List<Tab>` + active tab). Splitting one Split produces a Splitter with two Splits. | desktop + iPad |
| **Tab** | one session view inside a Split. Carries `sessionId`, or (when empty) an optional worktree used only to pre-fill the SPEC-27 dialog. | desktop + iPad |
| **Session** | one agent run/conversation. Carries its worktree/branch as metadata. | all platforms |
| **Worktree** | **per-session metadata** — the tab label and the sidebar grouping key. **Not** a layout owner. | all platforms |

> **No more "mux pane."** SPEC-27 retires pi's server-side terminal-multiplexer
> execution slot (`PaneInfo`/`paneId`) along with native pi — all sessions are
> headless (pi via ACP, codex via app-server). The old naming collision (server
> "mux pane" vs UI "pane") is
> therefore gone; this spec still adopts **Split/Tab** vocabulary on its own
> merits and never calls a UI region a "pane."

Naming rules that kill the confusion:

- **"Split" = UI leaf region** (holds tabs). **"Splitter" = the divider node.**
  Neither is ever called "pane".
- The `PaneNode`/`PaneLeaf`/`PaneSplit` **class names** are renamed to
  `SplitNode`/`Split`/`Splitter` by this spec (see the Flutter section); with
  the server mux pane gone there is no remaining `paneId`/`PaneInfo` wire field
  to reconcile.

---

## Decisions (frozen)

1. **Recursive split tree.** Grids/nested layouts via `Splitter` internal nodes
   (H/V + ratio) and `Split` leaves. Same tree shape as today's `PaneSplit`;
   the leaf changes (see below).
2. **A Split holds a tab strip**, not a single session: `List<Tab>` + an active
   tab id. Splitting/closing operate on Splits; tab open/close/switch/reorder
   operate within a Split.
3. **One workspace, worktree-agnostic.** There is exactly **one** layout. Its
   Tabs may host sessions from **any** worktree simultaneously. (Multiple named
   workspaces are out of scope — see Out of scope.)
4. **A Tab is `{ id, sessionId? }`.**
   - `sessionId != null` → renders that session's chat (a draft session with no
     messages yet shows an empty transcript + composer). Worktree label is
     derived from the session's metadata.
   - `sessionId == null` → the empty placeholder with a **New session** button
     (decision 7). There is **no inline harness/worktree picker** in a Tab.

   > New sessions are created through a dedicated **New session dialog**, not
   > inline in a Tab. That dialog (worktree · harness · config options, and
   > the merge of the "existing worktree" and "new worktree" flows) is specified
   > in [SPEC-27](./2026-07-24-SPEC-27-new-session-config-at-spawn.md); it
   > replaces today's `WorktreeStartView`.
5. **A session appears in at most one Tab (unique).** Opening a session that is
   already open focuses its existing Tab rather than creating a duplicate.
6. **Sidebar session click → reveal.** Find the Tab hosting that session
   anywhere in the tree; make its Split the active Split and that Tab the active
   Tab. If no Tab hosts it, open a new Tab for it in the **active Split** and
   activate it. **No worktree/workspace switch** — everything coexists in one
   layout.
7. **Empty workspace → placeholder.** On fresh launch (no saved layout) the
   workspace is a single empty Split with one empty Tab (`sessionId == null`)
   showing a "Select a session, or start a new one" placeholder with a **New
   session** button that opens the SPEC-27 dialog.
8. **Layout persists across restarts.** The whole tree (splitters, splits, each
   split's tab strip + active tab, and the active split) serializes to
   `SharedPreferences` under one key, following the `PreferencesController`
   pattern (nullable prefs → ephemeral in tests; `.load()` factory; write-through
   full dump).
9. **Mobile unchanged.**
10. **iPad reaches the workspace via a platform/size shell (frozen).** Today
    `main.dart` calls `runDesktopApp()` only for `Platform.isMacOS`; iOS
    (including iPad) always enters the mobile router. Since this workspace is
    promised for **desktop *and* iPad**, this spec adds an entry-point/shell
    change: route to the workspace UI (`WorkspaceView` + its desktop-style
    providers) when running on **macOS, or on iPadOS / a large-screen
    (regular×regular size-class) iPad**, and keep the mobile push-navigation
    router on iPhone / compact widths. The decision is by **size class /
    form factor**, not just `Platform`, so a Stage-Manager or split-view iPad in
    a compact width may fall back to the mobile router.

---

## Relationship to SPEC-20

SPEC-20 ("the worktree owns the pane tree") is **superseded and reverted** by
this spec:

- SPEC-20's per-worktree keyed workspace (`Map<path, PaneTreeState>`,
  swap-on-select) is **removed**. There is one worktree-agnostic tree instead.
- SPEC-20 removed `PaneLeaf.worktree`; this spec restores a per-leaf worktree —
  now on the **Tab** (`Tab.worktree`), as the starter hint (decision 4). This is
  closer to the pre-SPEC-20 model, plus tabs.
- SPEC-20's decision 4 ("selecting a session swaps to its worktree's tree") is
  replaced by decision 6 ("reveal the tab in the one shared layout").

If SPEC-20 was already implemented, this spec reshapes those files; if not, this
spec is implemented directly and SPEC-20 is marked superseded in the specs
README.

---

## Current-state anchors (real code this reshapes)

- `app/lib/desktop/chat/panes/pane_node.dart` — immutable `PaneNode`
  (`PaneLeaf {id, sessionId?}` / `PaneSplit {id, axis, first, second, ratio}`),
  pure tree functions (`splitLeaf`, `closeLeaf`, `setRatio`, `moveLeaf`,
  `mapLeaves`, `firstLeafWhere`, `containsLeaf`), `DropEdge`, `nextPaneId`.
- `app/lib/desktop/chat/panes/pane_tree_controller.dart` —
  `StateNotifier<PaneTreeState>` (`{root, activeLeafId, worktree}`) / workspace
  map, JSON persistence under `kPaneWorkspacePrefsKey`.
- `app/lib/desktop/chat/panes/pane_tree_view.dart` — renders the tree;
  `_PaneLeafView` → `DesktopChatPane`.
- `app/lib/desktop/chat/panes/pane_header.dart` — per-leaf header/controls.
- `app/lib/desktop/chat/desktop_chat_pane.dart` — `worktree` + `sessionId`
  params; renders `WorktreeStartView` for a sessionless leaf.
- `app/lib/desktop/chat/selected_session.dart` /
  `selected_worktree.dart` — `selectedSessionProvider`,
  `selectedWorktreeProvider`, `selectSessionExclusive`, `closePane`,
  `newPaneInActiveWorktree`, `selectWorktree`.
- `app/lib/desktop/chat/keymap_scope.dart` — `_splitPane`, split/close keymap
  wiring.
- `app/lib/shortcuts/shortcut_action.dart` — `splitPaneVertical`,
  `splitPaneHorizontal`, "new session in pane", "close pane" actions (labels/ids
  reference "pane"; rename to split/tab vocabulary).
- `app/lib/desktop/chat/desktop_sidebar.dart` (`_WorktreeGroup`),
  `new_session_dialog.dart` — sidebar session/worktree selection call sites.
- `app/lib/desktop/desktop_app.dart` — `.load()` persistence wiring template.
- `app/lib/main.dart` — platform entry: `runDesktopApp()` gated on
  `Platform.isMacOS` today; **decision 10 changes this** to also route iPadOS /
  large size-class into the workspace shell.
- `app/test/desktop/chat/pane_tree_view_test.dart` and pane_node/controller
  tests — assume the single-session-per-leaf model; rewritten here.

---

## Target model

### Node (`split_node.dart`, renamed from `pane_node.dart`)

```dart
sealed class SplitNode {
  String get id;
  Map<String, Object?> toJson();
  static SplitNode fromJson(Map<String, Object?> j) => switch (j['k']) {
    'split'    => Split.fromJson(j),
    'splitter' => Splitter.fromJson(j),
    final o    => throw FormatException('unknown split node kind: $o'),
  };
}

/// A leaf region: a strip of tabs plus which one is active.
final class Split extends SplitNode {
  const Split({required this.id, required this.tabs, required this.activeTabId});
  final String id;
  final List<Tab> tabs;      // never empty for a live Split; see closeTab
  final String activeTabId;  // must reference a tab in [tabs]
}

/// One session view in a split.
final class Tab {
  const Tab({required this.id, this.sessionId, this.worktree});
  final String id;
  final String? sessionId;         // null → empty placeholder tab
  // When sessionId == null, an optional worktree used ONLY to pre-fill the
  // SPEC-27 New session dialog's Worktree field. It is NOT an inline picker
  // (WorktreeStartView is removed — decisions 4 & 7).
  final SelectedWorktree? worktree;
}

/// An internal divider node (was PaneSplit).
final class Splitter extends SplitNode {
  const Splitter({required this.id, required this.axis, required this.first,
                  required this.second, this.ratio = 0.5});
  final String id;
  final Axis axis;      // horizontal → side-by-side; vertical → stacked
  final SplitNode first, second;
  final double ratio;   // first child's fraction, clamped kMin..kMax
}
```

Pure tree functions carry over, renamed to the Split/Splitter vocabulary and
generalised from "leaf hosts a session" to "leaf hosts tabs":

- `splitLeaf` → `divideSplit(root, targetSplitId, axis, Split newSplit, {newAfter, splitterId})`
- `closeLeaf` → `removeSplit(root, targetSplitId)` (collapses the parent
  Splitter into the surviving sibling; never yields an empty tree)
- `setRatio(root, splitterId, ratio)` (unchanged semantics)
- `moveLeaf` → `moveSplit(root, sourceSplitId, targetSplitId, DropEdge)`
- `mapLeaves` → `mapSplits`; `firstLeafWhere` → `firstSplitWhere`;
  `containsLeaf` → `containsSplit`
- New tab helpers (pure, on a single `Split`): `addTab`, `removeTab`
  (returns a `Split` or `null` when the last tab is removed), `activateTab`,
  `reorderTab`, and a tree-wide `findTab(root, sessionId) → (splitId, tabId)?`.

Ids: keep an incremental generator (`nextNodeId()` → `split-N` / `splitter-N` /
`tab-N`), deterministic for tests.

### Controller (`workspace_controller.dart`, from `pane_tree_controller.dart`)

```dart
@immutable
class WorkspaceState {
  const WorkspaceState({required this.root, required this.activeSplitId});
  final SplitNode root;
  final String activeSplitId;
}
```

One workspace (no per-worktree map). API:

| Method | Behaviour |
|---|---|
| `divideActive(Axis)` | split the active Split; new Split gets one empty starter Tab; it becomes active. |
| `closeActiveSplit()` | remove the active Split (collapse parent); active follows the surviving sibling. No-op when it is the only Split. |
| `setActiveSplit(id)` | focus a Split. |
| `setRatio` / `adjustRatio` | resize a Splitter. |
| `moveSplit(source, target, edge)` | drag a Split to another Split's edge. |
| `openTab(splitId, Tab)` | append a Tab to a Split and activate it. |
| `closeTab(splitId, tabId)` | remove a Tab; if it was the last Tab in the Split, remove the Split (collapse) unless it is the only Split, in which case reset it to one empty starter Tab. |
| `setActiveTab(splitId, tabId)` | switch the active Tab in a Split. |
| `moveTab(fromSplit, tabId, toSplit, index)` | drag a Tab between Splits. If this empties the source Split, it collapses like `closeTab` (parent Splitter collapses into the sibling) — or, when the source is the only Split, it resets to a single empty placeholder Tab. |
| `revealSession(String sessionId)` | **decision 6.** `findTab` in the tree → if found, `setActiveSplit` + `setActiveTab` on it. Else `openTab` on the active Split with a new `Tab(sessionId)` (worktree comes from the session's own metadata — not stored on the bound tab). Enforces decision 5 (unique). |
| `unbindSession(sessionId)` | remove the Tab hosting a quit/removed session from wherever it is (collapse empty Splits per `closeTab`). |

Persistence: `.load(prefs)` + write-through on every mutation, serializing
`{root, activeSplitId}` under one key (rename `kPaneWorkspacePrefsKey` →
`kWorkspacePrefsKey`). Nullable prefs → ephemeral (tests + provider default).

### Selection providers (`selected_session.dart`)

- `selectSessionExclusive(ref, id)` → calls `revealSession(id)` (the session's
  worktree is metadata on the session itself — not passed to or stored on the
  Tab). `selectedSessionProvider` stays in sync for the sidebar highlight and
  mobile.
- `selectedSessionProvider` is derived from / kept consistent with the active
  Split's active Tab's `sessionId` so the sidebar highlight tracks the visible
  tab.
- `selectedWorktreeProvider`: sidebar grouping no longer swaps layouts; a
  worktree "select" (e.g. "start a session in worktree W") opens a starter Tab
  (`Tab(worktree: W)`) in the active Split via `openTab`, rather than swapping
  the view.
- `closePane`/`newPaneInActiveWorktree` → renamed to `closeActiveSplit` /
  `newTabInActiveSplit` semantics.

### View (`split_tree_view.dart` + `split_view.dart`, from the pane views)

- `WorkspaceView` watches `WorkspaceState`; renders `root`.
- A `Splitter` renders a resizable two-child divider (as today's `PaneSplit`
  view).
- A `Split` renders a **tab bar** (its `tabs`, active highlighted, close/reorder
  affordances, `+` opens the SPEC-27 New session dialog) above the active Tab's
  body.
- The Tab body reuses `DesktopChatPane`: `sessionId != null` → chat; else the
  **empty placeholder** ("Select a session, or start a new one" + a **New
  session** button that opens the SPEC-27 dialog, pre-filled with `tab.worktree`
  when set). `WorktreeStartView` is **not** used (removed — decisions 4 & 7).
- Drag-and-drop: Splits still drag to a `DropEdge` (`moveSplit`); Tabs drag
  within/between tab bars (`moveTab`).

### Shortcuts (`shortcut_action.dart`, `keymap_scope.dart`)

Rename actions to the new vocabulary and add tab actions:
`splitPaneVertical`/`splitPaneHorizontal` → `splitVertical`/`splitHorizontal`
(divide active Split); `closePane` → `closeSplit`; add `newTab`, `closeTab`,
`nextTab`, `prevTab`. Keep existing keybindings; update labels/descriptions to
"split"/"tab" wording.

---

## Plan (TDD; verify each step with `flutter test --no-pub` + `flutter analyze --no-pub`)

1. **Node.** Rename to `SplitNode`/`Split`/`Splitter`, add `Tab`, move
   session-hosting from leaf → tab strip. Port pure tree functions; add tab
   helpers + `findTab`. Unit tests: JSON round-trip for nested trees with
   multi-tab splits; `divideSplit`/`removeSplit`/`moveSplit` identity
   preservation; `findTab` locates a session; tab add/remove/activate/reorder;
   removing the last tab collapses/resets per decision.
2. **Controller.** `WorkspaceState` + ops above. Tests: divide seeds a starter
   Tab; `revealSession` focuses an existing Tab (no duplicate — decision 5) and
   otherwise opens one in the active Split; `closeTab` collapses an emptied
   Split but resets the sole Split to a starter Tab; `unbindSession` removes a
   session's Tab wherever it is; cross-worktree Tabs coexist in one tree.
3. **Persistence.** `.load(prefs)` + write-through; ephemeral without prefs.
   Tests: mutate → reload → identical workspace; corrupt JSON → empty workspace
   (single starter Split); a persisted Tab whose `sessionId` no longer resolves
   falls back to the **empty placeholder** (New session button, no crash). Wire
   `.load()` in `desktop_app.dart`.
4. **View + shortcuts + call sites.** Tab bar + splitter views; drag/drop for
   Splits and Tabs; rename shortcut actions and update `keymap_scope.dart`,
   `desktop_sidebar.dart`, `new_session_dialog.dart`, `selected_session.dart`.
   Rewrite the pane widget/unit tests for the Split/Tab model (reveal-in-place,
   tab switching, empty placeholder, cross-worktree coexistence).
5. **iPad platform shell (decision 10).** Update `main.dart` (+ a size-class
   listener) to route macOS and large-screen iPadOS into the workspace shell,
   iPhone/compact into the mobile router. Tests: the router selection picks the
   workspace for a regular×regular size class and the mobile flow for compact;
   the workspace's desktop-style providers initialize on iPad.
6. **Green gate.** `flutter analyze --no-pub` clean (`--fatal-infos`);
   full `flutter test --no-pub` green; `app/tool/audit.sh` passes.

---

## Risks & notes

- **Large test churn.** The pane tests encode single-session-per-leaf and (if
  present) SPEC-20's per-worktree swap. They are rewritten, not tweaked —
  expected and intended.
- **Sidebar highlight sync.** `selectedSessionProvider` becomes a mirror of the
  active Split's active Tab. Every writer must route through the controller;
  audit sidebar, new-session dialog, keymap_scope, tests for stray direct
  `.state =`.
- **Dead sessions after restart.** A persisted Tab may reference a session id
  that no longer exists. Resolve-time guard: such a Tab renders the empty/starter
  state instead of crashing (mirror SPEC-20's guard).
- **Unique-session invariant.** `openTab`/`revealSession` must check `findTab`
  first so a session never lands in two Tabs (decision 5).
- **Empty-Split invariant.** A live Split always has ≥1 Tab; the sole Split can
  never be fully closed (resets to a starter Tab).

## Out of scope

- **Multiple named workspaces** (a workspace switcher). One workspace only; the
  vocabulary leaves room to add this later without reshaping the tree.
- Cross-device layout sync (layout is local prefs, per device).
- **Mobile:** unchanged (no workspace/split/tab there).
