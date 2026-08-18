# SPEC-desktop-sidebar-topbar-restructure — Desktop sidebar & topbar restructure (foldable/resizable + slim chrome)

**Status:** In progress · **Depends on:** SPEC-desktop-chat-app (desktop chat app), SPEC-repo-centric-home (repo-centric home)
**Roadmap:** new — evolves the desktop two-pane shell's information architecture
**Source of truth:** skeletoner `makit-macos-desktop` (v001 → working diff), plus the clarifications recorded under [Consensus decisions](#consensus-decisions-source-of-truth).

**Touches (new):**
`app/lib/desktop/chat/sidebar_layout.dart`,
`app/test/desktop/sidebar_layout_test.dart`

**Touches (edit):**
`app/lib/desktop/chat/desktop_chat_shell.dart` (foldable + resizable shell),
`app/lib/desktop/chat/desktop_sidebar.dart` (fold button, collapsible worktree, compact tiles, status dot, PR line),
`app/lib/desktop/chat/desktop_chat_pane.dart` (`_PaneHeader` slimmed: drop branch/status/subtitle/divider, smaller avatar, unfold affordance),
`app/test/desktop/desktop_sidebar_test.dart`,
`app/test/desktop/desktop_chat_pane_test.dart`

**Scope:** desktop only. The mobile screens (`home_screen.dart`, `session_screen.dart`) are **out of scope** for this spec.

---

## Goal

The desktop two-pane shell (a fixed 320px sidebar + a chat pane with a
chip-heavy header) is being reshaped based on the reviewed skeleton. Two
threads of change:

1. **Sidebar becomes a real panel** — foldable (fully hidden) and resizable
   (250–450px), with a fold control in the top drag strip and an unfold control
   in the chat pane when hidden.
2. **Chrome gets quieter** — session tiles collapse to a single line (no
   avatar, no message preview) with a small animated status dot instead of a
   text chip; worktree rows become collapsible (click to show/hide their
   sessions) with the PR pill on its own line; and the chat-pane header sheds
   its branch chip, status chip, agent-name subtitle, and bottom divider.

Branch and status context now live **only in the sidebar** — the pane header is
just the agent avatar + session title + actions menu.

**Non-goals (explicit YAGNI):**
- **No persistence** of fold state or width. State is in-memory and resets on
  restart; a `shared_preferences`-backed store can be layered on later without
  touching call sites (the providers are the seam).
- No icon-rail "mini sidebar" — fold means fully hidden, nothing else.
- No sidebar animation/slide choreography beyond the default rebuild.
- No changes to the transcript body, composer, or any store/protocol code.

## Consensus decisions (source of truth)

1. **Fold = fully hidden** (width 0, removed from the row), not a mini rail.
2. **Unfold affordance lives in the chat-pane header top-left**, inset past the
   macOS traffic lights; the fold affordance lives in the sidebar's top drag
   strip, also inset past the traffic lights.
3. **Resize bounds:** min `250`, max `450`, default `320` — clamped on drag.
4. **Worktree row click → collapse/expand its sessions** (default expanded). A
   leading chevron reflects state.
5. **Session tile is single-line:** title + a small status indicator. **No
   avatar, no last-message preview.** The status indicator is a colored dot that
   **pulses** for active states (running / awaiting-input / awaiting-approval)
   and is solid otherwise; `idle` shows nothing. Pending sessions keep the
   `draft` tag (unchanged, preserves the DRAFTS section semantics).
6. **PR pill moves to its own line** under the worktree branch row; the diff
   chip stays inline on the branch row.
7. **Pane header is slimmed:** remove `BranchChip`, `SessionStatusChip`, the
   agent-name subtitle, and the header's bottom `Divider`. Avatar shrinks
   (28 → 24).
8. **Untitled-session fallback is the agent name.** The skeleton moves the
   pane's agent subtitle ("codex") into the sidebar as a session title: a
   session with an empty title shows its agent name (`pi`/`codex`/`claude`),
   not the raw session id.
9. **Repo-name casing is a no-op.** The skeleton's `MAKIT → makit` change is
   presentational only; code already renders `repo.name` verbatim. Do not add
   any case transformation.

## Contract (land first — unblocks parallel work)

`app/lib/desktop/chat/sidebar_layout.dart` is the shared seam every workstream
depends on. It is tiny and stable, so it lands in a **preamble step** before the
parallel workstreams start:

```dart
const double kSidebarMinWidth = 250;
const double kSidebarMaxWidth = 450;
const double kSidebarDefaultWidth = 320;

/// Whether the sidebar is folded away (fully hidden).
final sidebarCollapsedProvider = StateProvider<bool>((_) => false);

/// Current sidebar width (px), clamped to the min/max above.
final sidebarWidthProvider = StateProvider<double>((_) => kSidebarDefaultWidth);
```

Once this file exists, the shell, sidebar, and pane workstreams can proceed
concurrently against these two providers without touching each other's files.

## Parallelizable plan

**Preamble (blocking, ~5 min):** create `sidebar_layout.dart` (the contract
above) + its unit test. Everything else forks from here.

Then four independent workstreams, each owning a disjoint file set:

| WS | Owns (edits) | Depends on | Can run with |
|----|--------------|------------|--------------|
| **A — Shell** | `desktop_chat_shell.dart` | contract | B, C, D |
| **B — Sidebar content** | `desktop_sidebar.dart` | contract | A, C, D |
| **C — Pane header** | `desktop_chat_pane.dart` | contract | A, B, D |
| **D — Tests** | `sidebar_layout_test.dart`, `desktop_sidebar_test.dart`, `desktop_chat_pane_test.dart` | contract | A, B, C |

No two workstreams write the same file, so they merge without conflict.

### WS-A — Foldable/resizable shell (`desktop_chat_shell.dart`)
- Convert `DesktopChatShell` to a `ConsumerWidget`.
- Watch `sidebarCollapsedProvider` + `sidebarWidthProvider`. When collapsed,
  omit the sidebar and its divider from the `Row`; otherwise render the sidebar
  at `width`.
- Replace the static `VerticalDivider` with a `_SidebarResizeHandle`: an 8px
  `MouseRegion(resizeColumn)` + `GestureDetector.onHorizontalDragUpdate` that
  does `width.notifier.update((w) => (w + dx).clamp(min, max))`, wrapping a 1px
  `VerticalDivider`.
- **Verify:** `flutter analyze --no-pub`; manual: drag resizes within bounds.

### WS-B — Sidebar content (`desktop_sidebar.dart`)
- `_Header` → `ConsumerWidget`; keep the full-width `DragToMoveArea`, overlay a
  `Hide sidebar` `IconButton` at `left: 72` (clears traffic lights) that sets
  `sidebarCollapsedProvider = true`.
- `_WorktreeGroup` → `StatefulWidget` with `_expanded` (default `true`). Branch
  row is an `InkWell` toggling `_expanded`, with a leading `expand_more` /
  `chevron_right` chevron. Sessions render only when expanded.
- Move `PrPill` out of the branch row onto its own indented line below it; keep
  `DiffChip` inline.
- `_SessionTile` → drop `leading: AgentAvatar` and the `subtitle` preview; make
  it single-line/compact. Replace `SessionStatusChip` with a private
  `_StatusDot` (pulsing `FadeTransition` for active states, solid otherwise).
  Keep the `draft` tag for pending sessions. Untitled sessions fall back to the
  agent name (decision 8).
- **Verify:** `flutter test test/desktop/desktop_sidebar_test.dart`.

### WS-C — Slim pane header (`desktop_chat_pane.dart`)
- In `build`, delete the branch-lookup loop and the `branch` argument; remove
  the `Divider` under `_PaneHeader`.
- `_PaneHeader`: drop the `branch` field, `BranchChip`, `SessionStatusChip`, and
  the agent-name subtitle `Text`. Shrink `AgentAvatar` to `size: 24`.
- Read `sidebarCollapsedProvider`; when collapsed, add left inset past the
  traffic lights and a leading `Show sidebar` `IconButton` that sets it back to
  `false` (wrap the strip so the window stays draggable there).
- **Verify:** `flutter test test/desktop/desktop_chat_pane_test.dart`.

### WS-D — Tests
- `sidebar_layout_test.dart`: clamp behavior + default/collapsed defaults.
- `desktop_sidebar_test.dart`: existing cases still pass (titles, `+12/−3`,
  `PR #42`, `draft`, DRAFTS, empty). Add: worktree row tap hides/shows sessions;
  fold button flips `sidebarCollapsedProvider`.
- `desktop_chat_pane_test.dart`: existing header/empty cases pass; add: no
  `BranchChip`/`SessionStatusChip` in the header; unfold button appears only
  when collapsed and clears the flag.
- **Verify:** `flutter test test/desktop`.

## Integration checkpoint (after all WS merge)
- `flutter analyze --no-pub` clean.
- `flutter test test/desktop` green.
- Manual smoke: fold hides the sidebar and surfaces the pane unfold button;
  unfold restores it; drag resizes within 250–450; worktree rows collapse; tiles
  are single-line with a pulsing dot on running sessions; the pane header shows
  only avatar + title + actions menu.
