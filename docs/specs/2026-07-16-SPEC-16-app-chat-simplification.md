# SPEC-16 — App chat/store simplification (dead code, dedup, typed models)

**Status:** Proposed · **Priority:** P1 · **Source:** `docs/research/2026-07-16-code-quality-audit.md` §Blocker B2, §1 S4–S6, §2 P6
**Scope:** `app/lib/ui/session/**`, `app/lib/desktop/chat/**`, `app/lib/store/models.dart`. Behavior-preserving.

---

## 🚦 Branch & worktree gate (NO GO if not met)

This spec **MUST** be implemented in a **new git worktree branched from `chore/code-quality-review`**, and its **pull request MUST target `chore/code-quality-review`** (not `main`).

- Base branch: `chore/code-quality-review`
- PR target branch: `chore/code-quality-review`

If either condition is not satisfied, **this spec is NO GO**.

```bash
git fetch origin chore/code-quality-review
git worktree add ../spec-16-app-chat -b spec-16/app-chat-simplification origin/chore/code-quality-review
```

---

## Goal

Delete dead abstraction, collapse copy-pasted rendering logic, and replace
raw-string/boolean tool state with typed models — matching the codebase's
existing enum conventions (`SessionStatus`, `ApprovalPolicy`). Target: ~340 lines
removed and the mobile/desktop transcript renderers unified.

## Work items

### B2 — Delete the dead `ToolRenderer.card` layer *(verified dead)*

- **Where:** `app/lib/ui/session/tool_renderers.dart:53, 55-64, 67-137` + every
  `subtitle()` override.
- **Verified:** the transcript renders via `ToolCallCard`, which only reads
  `renderer.icon` + `toolDisplayName`. **No** call site invokes `renderer.card(...)`
  or `renderer.subtitle(...)`. `card()`, `_DefaultCard`, `inlineInteractive`, and
  all `subtitle()` overrides (~130 lines) are dead; the library doc (lines 12-16)
  falsely claims the card renders inline.
- **Fix:** delete the card/subtitle/inlineInteractive surface; `ToolRenderer`
  collapses to `{ name, displayName, icon, detail() }`. Fix the library doc.
  Delete the redundant `_AskUserQuestionRenderer('AskUserQuestion')` (line 578) —
  the resolver already does a `toLowerCase()` fallback (`:590`).

### S4 — Collapse `foldEvents`'s three streaming accumulators

- **Where:** `store/models.dart:676-820` (message/thinking/tool cases).
- **Fix:** one generic `_upsertStream<T extends ChatItem>(items, index, id, create, append)`
  helper → three ~4-line call sites (message and thinking differ only in item
  type + the empty-final guard). Pure and unit-testable.

### S5 — Unify the desktop/mobile transcript renderer

- **Where:** `desktop/chat/desktop_chat_pane.dart` `_buildItem` +
  `_ThinkingLine`/`_ErrorBanner`/`_WorkingIndicator` vs
  `ui/session/session_screen.dart`.
- **Fix:** extract shared `ui/session/chat_transcript.dart` exposing
  `Widget chatItemWidget(ChatItem, {required void Function(ToolCallItem) onOpenTool})`
  plus shared `ThinkingLine`/`ErrorBanner`/`WorkingIndicator` (parameterize the
  cosmetic padding delta with a `compact` flag). Deletes ~120 lines of desktop
  fork and makes the "renders identically to mobile" claim true by construction.

### S6 — Collapse pane-tree recursion into 2 combinators

- **Where:** `desktop/chat/pane_tree_controller.dart` (`_activeLeaf`, `_pinLeaf`,
  `_ratioOf`, `_clearSession`, `_siblingFirstLeafId`), `desktop/chat/pane_node.dart`
  (`_findLeaf`, `firstLeafId`, `containsLeaf`).
- **Fix:** add `mapLeaves(node, PaneLeaf Function(PaneLeaf))` (rebuild) and
  `firstLeafWhere<T>(node, T? Function(PaneLeaf))` (search) to `pane_node.dart`;
  `_pinLeaf`/`_clearSession` become one-liners over `mapLeaves`;
  `_activeLeaf`/`_ratioOf`/`_findLeaf` become `firstLeafWhere`. Also fixes
  `setRatio` recursing into both children after a match.

### P6 — Typed tool status & risk; single `resultText`

- **Where:** `store/models.dart:627,644`; `ui/session/tool_call_card.dart:18-25`;
  `tool_renderers.dart:144,502,635`.
- **Fix:** add `enum ToolRisk { safe, risky, destructive }` (parsed at the model
  boundary, explicit unknown→safe) and `enum ToolStatus { running, ok, failed }`
  as a getter on `ToolCallItem`; UI switches exhaustively. Add
  `String get resultText => deltas.isNotEmpty ? deltas.join() : (output ?? '')`
  to kill the 3 copies with inconsistent precedence.

## Verification (definition of done)

- New unit test for `_upsertStream` / `foldEvents` streaming behavior (delta →
  finalize, empty-final guard).
- New unit tests for `mapLeaves`/`firstLeafWhere` on representative trees;
  existing `pane_tree_view_test.dart` still passes.
- Grep proves no remaining references to `ToolRenderer.card`, `_DefaultCard`,
  `inlineInteractive`, or `subtitle(`.
- Widget tests confirm desktop and mobile transcripts render the same item set.
- `flutter analyze --fatal-infos` clean; `app/tool/audit.sh` passes.

## Non-goals

- No visual redesign; cosmetic padding parity between mobile/desktop is
  acceptable via a flag, not a redesign. Do **not** disturb the pane-tree model
  beyond adding the two combinators.
