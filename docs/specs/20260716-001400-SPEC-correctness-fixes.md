# SPEC-correctness-fixes — Correctness fixes: multi-pane composer focus + draft-failure event ordering

**Status:** Proposed · **Priority:** P0 (blockers) · **Source:** `docs/research/2026-07-16-code-quality-audit.md` §Blockers B1, §2 P1
**Scope:** desktop app + server. Two verified correctness defects — no feature work.

---

## 🚦 Branch & worktree gate (NO GO if not met)

This spec **MUST** be implemented in a **new git worktree branched from `chore/code-quality-review`**, and its **pull request MUST target `chore/code-quality-review`** (not `main`).

- Base branch: `chore/code-quality-review`
- PR target branch: `chore/code-quality-review`

If either condition is not satisfied, **this spec is NO GO** — do not start, do not open a PR against any other base.

```bash
# Create the worktree from the required base
git fetch origin chore/code-quality-review
git worktree add ../spec-14-correctness -b spec-14/correctness-fixes origin/chore/code-quality-review
```

---

## Goal

Fix the two defects the audit verified as **correctness bugs**, each covered by a
failing-first test (TDD, per AGENTS.md).

## B1 — Multi-pane composer shares one app-lifetime `FocusNode`

- **Where:** `app/lib/desktop/chat/composer_focus.dart:8`; consumed at
  `app/lib/desktop/chat/desktop_chat_pane.dart:219`; driven at
  `app/lib/desktop/chat/keymap_scope.dart:162`.
- **Defect:** `desktopComposerFocusProvider` is an app-lifetime singleton
  `FocusNode`. Each `_PaneLeafView` (`pane_tree_view.dart:267`) renders a
  `DesktopChatPane` whose `Composer` binds that same node. Two live sessions
  side-by-side → two `TextField`s attach to one `FocusNode` → illegal
  double-attach (debug assertion; release = undefined focus). Breaks the
  headline pane-split feature (#65).
- **Fix:** make the composer focus node **per-leaf**, not global. Either a
  `Provider.family<FocusNode, String>` keyed by leaf id, or have
  `DesktopChatPane` own a `FocusNode` in its `State` and dispose it. Route the
  global "focus composer" shortcut (`keymap_scope.dart`) to the **active leaf's**
  node via the pane-tree controller.

## P1 — `send.message` emits a `seq:0` event, bypassing `Session.record()`

- **Where:** `server/src/server.ts:287-294`.
- **Defect:** on draft-promotion failure the WS handler hand-builds
  `session.emit("event", { seq: 0, ... })`. The event is **unpersisted** and its
  `seq:0` collides with / precedes every real event, so a reconnecting client
  replaying by seq mis-orders or drops it. Also a layering leak (feature logic in
  the WS handler).
- **Fix:** move draft promotion into the manager and route the failure through
  the session's own pipeline (e.g. `Session.recordError(message)` → `record()`)
  so it gets a real monotonic seq and is persisted. The WS handler should just
  `await` the manager call and let the error surface as a normal event.

## Verification (definition of done)

- New failing-first Flutter widget test: split with **two** bound sessions;
  assert both composers mount and each is independently focusable/typable.
  (Current `pane_tree_view_test.dart` only pins one session — extend it.)
- New failing-first server test: draft promotion failure produces a persisted
  `session.error` event with a **non-zero, monotonic** seq that replays in order.
- `flutter analyze --fatal-infos` clean; `app/tool/audit.sh` passes.
- `cd server && pnpm typecheck && pnpm test` green.

## Non-goals

- No changes to pane layout, split UX, or the draft/worktree flow beyond the
  focus-node ownership and the error-routing path.
