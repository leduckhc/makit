# SPEC-composer-adaptive-input — Composer: adaptive input bar + send-on-content

**Status:** implemented · **Depends on:** none · **Touches:**
`app/lib/ui/composer/composer.dart`, `app/test/composer_test.dart`

## Goal

Make the phone composer (the message input bar) behave like a modern chat input:
hide the send button until there is something to send, grow the field to a
comfortable multi-line size when active, and let the user collapse it back to the
resting 1-line form.

## Why

Today the composer is a single static row — `[+] [TextField] [mic] [send]` —
where the send button is always visible (even when empty) and the field is a
1-line input that silently grows up to 5 lines. That is visually noisy and gives
no clear "resting" vs "active" state. Consensus from a focused UX round:

1. **Send button** should appear only when the field is non-empty (with a smooth
   fade), not be permanently shown.
2. **Active state** should be larger — a fixed 3-line field — so typing a real
   message does not feel cramped.
3. The active state must be **dismissable** back to the compact 1-line form
   `[+] Messages … [mic]`.

## UX consensus (source of truth)

| Decision | Choice |
|----------|--------|
| Expand trigger | **Tap to focus = expand.** Losing focus collapses back to 1 line. No extra toggle button. |
| Send-button visibility | **Any non-empty text** (compact or expanded). Empty = hidden. |
| Expanded layout | **Field full-width on top; `[+] … [mic] [send?]` in an action row beneath it.** |
| `+` button in expanded | **Moved below** alongside mic/send (stays accessible). |
| Expanded height | **Fixed 3 lines** (scrolls internally once exceeded). |
| Collapse with text | **Keep text, show 1 line.** Collapsing does not clear the draft; send remains visible because text is non-empty. |

### States

- **Compact (unfocused):** `[+] [1-line field] [mic] [send?]`.
  - `send?` = present (faded in) iff the field is non-empty; otherwise absent.
- **Expanded (focused):** full-width **3-line** field, then a row
  `[+] [spacer] [mic] [send?]` beneath it.

### Transitions

- Focus the field → expand (height animates via `AnimatedSize`).
- Blur (focus lost) → collapse to compact (text preserved).
- Text becomes non-empty → `send` fades in.
- Text becomes empty (incl. after send/clear) → `send` fades out.

## Scope

### In
- Track `_hasText` (non-empty) and `_isFocused` (`FocusNode.hasFocus`) as state.
- Switch the field's `minLines`/`maxLines` between `1` (compact) and `3`
  (expanded) based on focus.
- Render compact as a single `Row`; render expanded as a `Column` with the field
  on top and the `+`/mic/send action row below.
- Send button wrapped in an `AnimatedSwitcher` so it fades in/out on text
  presence; `+` and mic are always visible (their position just moves).
- Preserve the existing ⌘/Ctrl+Enter send shortcut and the slash-command palette.
- Preserve the `glass` transparency mode (composer is rendered inside a
  `GlassSurface` on the session screen).

### Out
- Voice dictation and `@`-mention picker (both still `TODO(M6)` stubs) — unchanged.
- Any change to the slash palette, session screen layout, or transport/store.
- Per-line "grow past 3 lines" behavior — expanded is intentionally capped at 3
  and scrolls (YAGNI for now).

## Contracts touched

- `Composer` widget public API is unchanged (`onSend`, `commands`, `glass`).
  Callers (`session_screen.dart`) and the E2E helper
  `sendComposerText(tester, text)` (enter text → tap `Icons.arrow_upward`) keep
  working unchanged.
- Internal state additions: `_hasText`, `_isFocused`; new listeners on the
  `TextEditingController` and `FocusNode` (removed in `dispose`).

## Implementation notes

- The send `AnimatedSwitcher` uses a **fade** (not a scale-from-zero) so the
  button is laid out at full size the moment text appears — it must remain
  hit-testable after a single `pump()` for the E2E helper and widget tests.
- `AnimatedSize` (220 ms, `easeOutCubic`, bottom-aligned) wraps the compact/
  expanded switch so the height change animates rather than snapping.
- The `TextField` keeps a stable controller + focus node across the compact ↔
  expanded rebuild, so text, selection, and focus survive the layout swap.
- `_hasText` is updated from **both** the controller listener (covers programmatic
  clears like `_send()` → `_ctrl.clear()`) and the `onChanged` callback (covers
  user typing, including under the test binding's `enterText`).

## Acceptance criteria

- [x] With an empty field, the send affordance (`Icons.arrow_upward`) is absent.
- [x] Typing non-empty text fades the send button in; clearing the field fades
      it out.
- [x] Tapping the send button sends the trimmed text and clears the field.
- [x] Unfocused, the field is exactly 1 line; focusing it grows it to a fixed
      3 lines.
- [x] Blurring the field after typing a draft collapses it back to 1 line
      **without losing the draft**, and the send button stays visible.
- [x] `flutter analyze` clean on `composer.dart`; `app/test/composer_test.dart`
      passes; existing `client_commands_test.dart` and E2E
      `sendComposerText` helper unaffected.

## Files

- `app/lib/ui/composer/composer.dart` — rewritten with compact/expanded states.
- `app/test/composer_test.dart` — new widget tests for the criteria above.

---

## UX fixes (addressing architect + reviewer feedback)

### B1: Collapse path now reachable

**Problem:** In the initial implementation, there was no way for users to dismiss the
expanded state on iOS because:
- The session screen ListView had no tap-to-unfocus handler
- The spec explicitly rejected a toggle button
- `maxLines:3` made the IME return key a newline (not "done"), so iOS keyboard had
  no dismiss key

**Solution:** Added `GestureDetector` with `HitTestBehavior.translucent` wrapping the
ListView in `session_screen.dart` (line 94). Tapping empty space (or any non-interactive
area) now dismisses focus, collapsing the composer. The gesture detector is translucent
so taps on message bubbles/cards still route to their widgets.

### B2: IME return key is context-aware

**Problem:** All three lines of the expanded field had `maxLines:3` with no
`textInputAction` — so the IME returned a **newline** regardless of focus state.
On iOS, this meant no hardware dismiss affordance even in compact (1-line) mode.

**Solution:** Set `textInputAction` dynamically:
- **Expanded (3 lines, `_isFocused = true`):** `TextInputAction.newline` →
  return key inserts a line break
- **Compact (1 line, `_isFocused = false`):** `TextInputAction.send` → return key
  submits the message

Added `onSubmitted` callback: only fire `_send()` when in compact mode (to avoid
accidental submission while drafting multi-line text). The IME now shows a
contextual key ("Done" or "Send" on iOS; "Enter" or "Send" on Android).

### B3: Better UI/UX polish

- **Bottom padding increased:** Changed `Composer` bottom padding from `8` to `24` in
  `session_screen.dart:271` so the expanded 3-line field does not get hidden under
  the system safe area on iOS with an active keyboard.
- **Test coverage:** Added a test for IME action (`test/composer_test.dart:78`)
  to lock in the context-aware behavior and prevent regression.

### Result

The "dismissable" requirement (spec §3) is now truly reachable by real users on all
platforms. Collapse-on-blur is no longer test-only; it works on production. IME
signals are platform-appropriate. Draft preservation still works; send remains visible
when collapsed with text.
