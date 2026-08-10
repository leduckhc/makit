# SPEC-49 — The notice you can copy and re-read (rev 2)

**Status:** Implemented (rev 2 — after two independent reviews) · **Priority:** P1 · **Branch:** `feat/status`
**Depends on:** SPEC-48 (`app/lib/status/` — this spec changes only how its notice is *presented*),
SPEC-30 (`app/lib/shortcuts/`) for the keyboard path.
**Mockup:** [`mockups/notice-copy-and-review.html`](../../mockups/notice-copy-and-review.html)
(P2/P3 there are **deferred** — see "What this spec does not do")

**Scope:** `app/lib/status/status_toast.dart` (the notice card: copy target, semantics, focus,
hover/focus pause, expand-on-contact), `app/lib/shortcuts/shortcut_action.dart` +
`keymap.dart` (one new action), `app/lib/desktop/chat/keymap_scope.dart` (wire it),
`DESIGN.md` + `docs/UX.md` (one note each). **No change to** `StatusEvent`, `StatusCenter`,
`ToastQueue`, `ActivityView`, the protocol, or any dependency.

---

## Goal

Make the app's own message something you can **take with you** and **read twice**, without
building a second notification system. SPEC-48 already moved the notice off the bottom-centre
`SnackBar` slot and gave it a durable record; what is left is that the message on screen is
hard to copy, sometimes impossible to copy, and expires while you are reaching for it.

## The complaint, and what is actually true on this branch

> "It is impossible to copy into clipboard in case of some troubles. I cannot review what was
> just popping. And overall this is really terrible experience on both desktop and mobile."

Verified against the tree, because two of the three have already moved:

| Claim | Status on `feat/status` | Cause |
|---|---|---|
| cannot copy | **still true, and worse than reported** | copy is a 13 px glyph in a 24 px button, and it is rendered **only when `e.hasDetail`** (`status_toast.dart:289`). A notice with no detail has *no copy affordance at all*. |
| cannot review (present) | **still true** | the dwell measures elapsed time, not attention: `grep -c MouseRegion status_toast.dart` → **0**. On desktop the notice expires while the pointer travels toward it. |
| cannot review (gone) | **partly fixed** | the Activity record holds it — but only if you go looking, and there is no keyboard path to the last one. |
| in the way (bottom slot) | **already fixed** | the notice is top-anchored specifically to spare the composer (`status_toast.dart:122-133`). On `main` it is still 72 bottom `SnackBar`s across 29 files. |

**Consequence for scope:** the "terrible placement" half of the complaint was a `main` symptom,
not a `feat/status` one. So this spec fixes copy and re-reading — which are still broken — and
does **not** redesign placement on a hypothesis. That is the single largest change from rev 1.

## Decisions

**D1 — Every notice is copyable, and the whole card body is the target.** Not only events with
`detail` (today's gate), and not a 13 px glyph. Success and info notices copy their head line;
that is still the thing someone wants to paste. The dedicated copy icon is **removed** in the
same change that makes the body the target — two ways to do one thing is how the 13 px button
survived this long.

**D2 — Copy is a semantic action, not just a tap target.** The card becomes focusable, `Enter`
and `Space` copy, and it carries a `Semantics` label plus a named custom action so a screen
reader can both find and perform it. The existing `Semantics(liveRegion: true)`
(`status_toast.dart:223`) stays and announces the confirmation. A notice whose whole purpose is
"you can re-read this" that is reachable only by pointer would be the same bug in a new costume.

**D3 — `toClipboardText()` does not change.** Rev 1 proposed a context block; re-reading the code
deleted the whole idea. `displayTitle` already carries `×$count`
(`status_event.dart:103`, used by the clipboard head at `:125`), so coalescing is covered. A
session *label* cannot be added without either `StatusCenter` importing the store (a cycle
`status_providers.dart` deliberately avoids) or a resolver threaded through four call paths, and
the app has no runtime version source (`package_info_plus` absent; the value exists in
`pubspec.yaml:4` / `Info.plist` but is not reachable without a new dependency or a build-time
define). Both were decoration on a string. **Rejected as YAGNI.**

**D4 — Pause on hover or focus. Not on touch-down, and no cap.** Pointer-enter (mouse) or focus
entering the card cancels its dwell timer; leaving restarts it with the **full** dwell for that
severity, because a notice you looked away from is news again. Rev 1's pointer-down freeze is
**cut**: on touch it competes with the tap that copies, and `_WorkspaceShellApp` means an iPad
runs the *desktop* shell (`main.dart:280-300`), so "desktop is mouse, phone is touch" is false
in this app. Rev 1's 30 s cap is **cut** with it — a cap is only needed because a pointer can
rest forever, and the reviewers were right that re-introducing an expiry is the original bug.
Hover is a deliberate act that ends when the pointer leaves.

**D5 — Contact or focus expands the notice in place; it opens nothing.** The one-line monospace
preview becomes the full `detail` as selectable text, reusing the block `ActivityView`'s expanded
row already renders. No route, no dialog, no third rendering.

**D6 — Copy confirms in place and posts nothing.** The card's own affordance reports
`Copied`, announced via the existing live region, then reverts. A toast about a toast is how a
status layer becomes a bureaucracy — and the guard for it is a test that counts the record's
events, not one that looks for a widget.

**D7 — Tapping the body copies; the chevron opens.** Today a tap navigates to Activity, which
throws away the thing you can see in order to show you a list containing it. Copy is the action
that cannot be performed any other way, so it gets the surface; navigation keeps an explicit,
focusable control. A secondary (right) click does **not** copy.

**D8 — One shortcut, one payload: `⌘⇧C` copies the newest notice.** One
`ShortcutAction.copyNewestNotice`, default `primary(keyC, shift: true)` — free today (no default
binding uses `keyC`; the composer claims only `keyV` for image paste) and shaped like the shipped
`openPorts: primary(keyP, shift: true)`. It reads the **record**, so it works after the card is
gone, which is the half of "I cannot review it" that a card cannot answer. Rev 1's
double-press-escalates-to-ten is **cut**: one chord that silently changes payload based on hidden
1 s state is two commands wearing one costume, the user cannot tell which payload they got, and
`DateTime.now()` is not controlled by `pump` so the test would be flaky. Copying many notices is
`ActivityView`'s existing **Copy all**.

**D9 — The shortcut obeys the existing settings-modal gate.** Rev 1 carved out an exemption;
that gate encodes a real principle (no global chat action fires behind the Settings overlay,
`keymap_scope.dart:154-164`) and one "safe" exception grows into arbitrary ones. **Cut.**

**D10 — Nothing is persisted, nothing is sticky, and nothing returns to the bottom slot.**
SPEC-48 D9 stands; dismissal removes the view, never the record.

## What this spec does not do

- **It does not dock the notice** (rev 1's P2: a 3 px→30 px layout-reserving strip) and **does not
  add a pull-down of recent notices** (rev 1's P3). Both are drawn in the mockup and both were
  cut by review, for the same reason: the placement complaint they answer is a `main` symptom
  that this branch already fixed, and their cost is real — a root `Column` under
  `MaterialApp.builder` puts every modal route and dialog below the strip, changes every screen's
  top-padding contract, invalidates every root golden, and breaks the opted-in
  `test/sim/status_sim_test.dart` harness (`:99`, `:136`). They stay deferred until someone is
  observed dodging a *top-anchored* notice. The design is preserved in the mockup, not lost.
- **It does not add transcript rows** for session failures (the mockup's structural idea). Its
  precedent is real (`ask_card.dart`, SPEC-25) and so is its cost: a local ephemeral row kind in
  a server-backed transcript plus a pollution policy. Its own spec, later.
- **No `Retry`** (no callback on `StatusEvent`), **no multi-format copy menu** (one good default;
  Activity exports many), **no new OS notifications**, **no persistence**, **no new dependency**.
- **Not the status *language*.** The `caution` tier, pulse semantics and the cross-session
  attention bar in [`mockups/status-language-ios-macos.html`](../../mockups/status-language-ios-macos.html)
  are a separate spec; the notice renders whatever `status_tone.dart` gives it.

## Review findings applied

Two independent codex reviews (`.piano/codex-jobs/20260810-093036-spec49-{tech,practice}/`).

**Accepted — design:** cut P2 and P3 (unproven placement hypothesis, high blast radius); cut the
context block (D3); cut the touch-down freeze and the 30 s cap (D4); cut the three-format menu;
cut the double-press escalation and the modal exemption (D8, D9); make accessibility and
input-mode arbitration first-class rather than unstated (D2, D4); state coalescing semantics
(D3 — already covered by `displayTitle`); specify the no-`detail` case (D1 — which turned out to
be the sharpest instance of the user's complaint).

**Accepted — factual corrections:** the reviewers found five wrong claims in rev 1 — that the app
has no version source at all (it has one, just not at runtime); that
`test/desktop/chat/keymap_scope_test.dart` is where the scope is tested (it is
`test/desktop/keymap_scope_test.dart`); that `status_lifetime_test.dart` could host a mount test
(it is a pure source scanner); that `reverse: true` preserves *any* reading position (it
preserves the tail; history has its own anchoring mechanism); and Flutter 3.44.9 (this checkout
runs **3.44.4**).

**Rejected — with reasons.** *"Cut the shortcut entirely"*: refused. "What was just popping" is
half the complaint and the card cannot answer it once gone; one chord over the record is the
cheapest complete answer, and it is the only keyboard path in the feature. *"Cut hover pause
too"*: refused. It is the direct fix for the desktop race where the notice expires while the
pointer travels toward it — narrowed to hover/focus rather than abandoned. *"The status suite
baseline is failing"*: refused as a finding. Re-run here it is **90/90 green**; the reviewer hit
the documented random `loading <file> [E]` flake that AGENTS.md says to judge by whether a file
fails in *all* runs.

## Verification

- `status_toast_test.dart` — copy is present and works for an event **with no `detail`** (the D1
  case that has no affordance today); a tap on the body copies exactly
  `event.toClipboardText()`; the chevron opens and does **not** copy; a secondary click does not
  copy; the confirmation appears in place, reverts, and **the record's event count is unchanged**
  (D6); `Enter` and `Space` copy when the card holds focus; the card exposes a `Semantics` label
  and a named copy action, and the live region announces `Copied` (D2); a mouse hover cancels
  expiry and leaving restarts the **full** dwell (D4); focus alone also pauses it; there is no
  cap timer; contact reveals the full detail as selectable text (D5).
- `keymap_test.dart` — `copyNewestNotice` defaults to `⌘⇧C` / `Ctrl+Shift+C`; **no two actions
  share a chord** in the default map (the invariant, rather than a brittle "nothing uses keyC");
  every enum value has a binding; it rebinds and persists like any action.
- `test/desktop/keymap_scope_test.dart` (**existing file, extended**) — the chord copies the
  newest event's `toClipboardText()`; with an empty record it copies nothing and does not throw;
  it does **not** fire while `settingsOpenProvider` is true (D9).
- Unchanged and must stay green: `status_event_test.dart`, `status_center_test.dart`,
  `toast_queue_test.dart`, `activity_*`, `no_snackbar_test.dart`, `status_lifetime_test.dart`,
  and the `test/sim/status_sim_test.dart` harness (this spec does not touch the mount points, so
  its goldens must not move — if one does, that is a regression, not an update).
- Every new test's bite proven by reverting only the production line (per AGENTS.md), with the
  mutation named in the plan.
- `flutter analyze --fatal-infos --no-pub` → `No issues found`. Baseline recorded before starting:
  `flutter test --no-pub test/status/` = **90/90 green**, `analyze` clean, Flutter **3.44.4**.
- Live proof: run the real app, trigger a real failure and a real success notice, and confirm by
  eye that one click copies something worth pasting, that hovering holds it, and that
  `⌘⇧C` works after it has gone.
