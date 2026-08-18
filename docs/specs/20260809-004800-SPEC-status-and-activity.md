# SPEC-status-and-activity — Activity: one durable, copyable record of everything the app tells you

**Status:** Draft · **Priority:** P2 · **Branch:** `feat/status`
**Depends on:** SPEC-background-wake-notifications/08 (`app/lib/notifications/` — actionable + background-wake OS
notifications), the diagnostics slice (`app/lib/diagnostics/log.dart` — `MakitLog`, the ring
buffer + stream + sinks shape this spec copies), SPEC-open-ports/43/44 (`ports_vocabulary.dart`,
`portKillOutcomeMessage` — outcome text that currently dies in a snackbar).
**Scope:**
*app (P1 — core):* `app/lib/status/status_event.dart` (new — `StatusEvent`, `StatusSeverity`,
`StatusSources`), `app/lib/status/status_center.dart` (new), `app/lib/status/status_providers.dart`
(new).
*app (P2 — toast):* `app/lib/status/toast_queue.dart` (new — pure crowding rules),
`app/lib/status/status_tone.dart` (new — glyph/hue per severity),
`app/lib/status/status_toast.dart` (new), mounted in `app/lib/main.dart` (both shells) and
`app/lib/desktop/desktop_app.dart`.
*app (P3 — surface):* `app/lib/status/activity_view.dart` (new — the one list),
`app/lib/status/activity_screen.dart` (new — phone route),
`app/lib/status/activity_badge.dart` (new — bell, count pill, desktop dialog),
`app/lib/app/routes.dart` + `router.dart`, the home bar, the desktop sidebar footer.
*app (P4 — migration):* the 72 `showSnackBar` call sites across 29 files; guard test.
*app (P5 — bridge):* `app/lib/notifications/notification_policy.dart` (`PendingNotification.status`),
`app/lib/notifications/notification_observer.dart`.
*docs:* `DESIGN.md` (§Components), `docs/NOTIFICATIONS.md`, `docs/UX.md`.

---

## Goal

Every message makit shows you today is a **`SnackBar`**: 72 of them, all inline, all default
styling, all gone in four seconds. Turn that layer into a **record** — one event log the user
can read, filter, expand and copy — and keep a toast as *one view* of that record rather than
the only place it ever exists.

## The three complaints, precisely

1. **"It cannot be copied."** ~30 of the 72 sites interpolate a raw exception into the
   message: `'Could not create worktree: $e'`, `'Pair failed: $e'`,
   `'${next.action} failed: ${next.reason}'`. A `SnackBar` has no selection, no copy, and one
   line of room, so the stack-trace tail — the only part worth sending to anyone — is
   truncated on screen and unrecoverable afterwards. The app that ships a *log uploader* for
   its own developers gives the user no way to quote the error they just saw.
2. **"It's only a short notice."** Four seconds, then it is gone forever. There is no "what
   just happened?" anywhere in the product. Miss it while looking at your phone's other half
   and the worktree either exists or it doesn't.
3. **"It's ugly."** `DESIGN.md` mentions snackbars **zero** times. This is the one surface in
   the app that was never designed: stock M3 dark pill, bottom-centre, square corners, no
   severity, no icon — and on mobile it lands **over the composer**, the one control the
   design doc actually protects.

## Why an event log, not a prettier snackbar

makit already has two thirds of a status system, and they don't talk to each other:

| Layer | Exists | Audience | Durable | Copyable |
|-------|--------|----------|---------|----------|
| `MakitLog` + Diagnostics | ✅ | developer | ✅ ring buffer | ✅ copy-all |
| `NotificationService` (SPEC-background-wake-notifications/08) | ✅ | user, **absent** | ❌ fire-and-forget | ❌ |
| **the app talking to you** | ❌ **snackbar** | user, **present** | ❌ | ❌ |

The missing layer is the *user-facing* sibling of `MakitLog`, so it is built as one: bounded
ring buffer, broadcast stream, snapshot getter, provider-injected, pure Dart core with no
Flutter import. Nothing new is invented where a precedent exists (D1).

It also closes the loop on notifications. An agent asking for approval raises an OS
notification you can answer from the lock screen — and then leaves **no trace at all**. "Did
I approve that? When?" is unanswerable today. Agent requests and app outcomes are the same
question ("what happened while I was here or away?"), so they land in the same inbox (D7).
That is why this is one feature and not two.

## Model

```dart
enum StatusSeverity { progress, success, info, warning, failure }

class StatusEvent {
  final String id;
  final DateTime ts;
  final StatusSeverity severity;
  final String title;      // the short human line — what the snackbar used to say
  final String? detail;    // the machine payload, verbatim: $e, stderr, a URL, a command
  final String source;     // 'worktree' | 'pairing' | 'ports' | 'agent' | … — filter + group
  final String? sessionId; // deep-link target, when the event belongs to a session
  final int count;         // coalesced repeats
  final bool read;
}
```

**`title` / `detail` is the whole fix.** Today the exception is concatenated into the human
sentence, which is why it is both unreadable and unrecoverable. Split them and the toast can
stay one calm line (`Could not create worktree`) while the record keeps every byte of
`$e` for the clipboard. `toClipboardText()` mirrors `LogRecord.toLine()` so the two copy
formats read as siblings (D2):

```
12:34:56.789 FAILURE [worktree] Could not create worktree
    FileSystemException: Creation failed, path = '…' (OS Error: File exists, errno = 17)
```

## Decisions

**D1 — `StatusCenter` copies `MakitLog`, it does not extend it.** Same shape (ring buffer +
broadcast stream + snapshot + provider), separate instance and separate capacity (200 events
vs 2000 log lines). Extending or filtering `MakitLog` was rejected: the log is level-filtered
noise for a developer (`minLevel` drops `debug` in release), while activity is a curated
user-facing feed where *nothing* may be dropped by a verbosity setting.

**D2 — Every status event is also written to `appLog`.** One line, `info`/`warn`/`error` by
severity, tag `status`. Free, and it means user-visible outcomes appear in diagnostics
uploads and in the server-side log next to the machinery that caused them. The reverse never
happens: log records do **not** become activity events (that is the firehose D1 rejects).

**D3 — The center is not context-bound, and that deletes code.** `ScaffoldMessenger.of(context)`
forces two workarounds that exist at **24 of the 72 sites**: capturing `messenger` in a local
before an `await` (≈18 sites, with comments explaining why), and `maybeOf` + `?.showSnackBar`
where the context may be gone (6 sites). A plain object reached through a provider is valid
across any async gap and is never null, so those workarounds are deleted rather than ported.

**D4 — Coalescing, because M3 queues.** Snackbars are shown strictly serially: three failed
worktree deletes = twelve seconds of notices you cannot skip. An event whose
`(severity, title, source)` matches the newest event within **8 s** bumps `count` instead of
appending, and the toast re-renders as `Could not delete worktree ×3`.

**D5 — Severity drives dwell, and nothing is sticky.** `info`/`success` 3 s, `progress` 4 s,
`warning` 6 s, `failure` 8 s. The record is the durable copy, so a toast that outstays its
welcome is pure obstruction. At most **3** toasts are visible; the rest wait behind a `+N`
chip that opens Activity. (`progress` gets a plain dwell, not a resolve handle: exactly two
call sites post progress, and a handle nobody holds is machinery for its own sake.)

**D6 — The toast is not glass, and it anchors at the top on both surfaces.** `DESIGN.md`
reserves Liquid Glass for the top bar and the composer, so the toast is a
`surfaceContainerHigh` card, `--radius-card`, 1px `outlineVariant` hairline, a 3px severity
stripe, and the sanctioned hues only: `success` → `primary`, `info` → `outline`,
`warning` → `kStatusWarning`, `failure` → `error`, `progress` → `primary`. Top anchoring is
the point: the snackbar's bottom-centre slot lands **on the composer** — the one control
`DESIGN.md` protects — and measuring a composer that lives inside a screen from a layer
mounted above the Navigator would be a coupling for no gain. Top also means one layout for
phone and desktop.

**D7 — Session lifecycle posts to the record, silently.** The notification layer already
decides which session transitions are worth a person's attention
(`diffStatusNotifications`) and then **threw that judgement away** whenever the app happened
to be in the foreground. Those transitions now always post — `error` → failure,
`awaiting-input`/`awaiting-approval` → warning, a finished turn → success — carrying the
`sessionId`, so "which session wanted something, and when?" finally has an answer.

They post **silently**: no toast, and they do not light the unread badge. A session you are
looking at already shows its own status dot, and the OS notification is what handles "you
weren't looking" — so a toast per finished turn would be noise, and a badge that always shows
a number is a badge nobody reads. `silent` therefore means *for the record only*, and the
event is born `read`.

**D7a — the approve/deny audit trail is deferred, deliberately.** Recording *which answer* you
gave would mean threading the response body out of `connection.respondTo` (`responded` carries
only a request id), i.e. changing the path SPEC-actionable-notifications made idempotent, to record a fact the
`awaiting-approval` row already implies. Not worth the risk in this slice.

**D8 — A guard test replaces the convention.** `showSnackBar` disappears from `app/lib`
entirely, and `test/status/no_snackbar_test.dart` fails the build if it comes back —
otherwise the 73rd inline snackbar lands in the next PR. `ScaffoldMessenger` is not banned
(the framework may still use it); the *call* is.

**D9 — Nothing is persisted across launches.** Activity is in-memory, like `MakitLog`'s
buffer. A durable store means a schema, a migration and a retention policy for data whose
value decays in minutes; the rolling log file already covers post-mortem. Revisit only if
"what happened while the app was killed?" turns out to be a real question.

**D10 — Corrections the render forced (audit harness: `test/sim/status_sim_test.dart`).**
Three things only an image could settle:

1. **The toast clears the app's own top bar** (`kToastInsetPhone` 60, `kToastInsetDesktop`
   40). Top-anchoring fixes the composer collision but re-creates it against the floating
   glass bar and the desktop title strip; the inset is per shell because only the shell knows
   what it parked there.
2. **`warning` takes `statusWarningText`, not `kStatusWarning`.** Measured, the vivid amber is
   **2.07:1** on the light surface — under even the 3:1 floor for a UI component, and these
   glyphs are 15 pt and load-bearing. The brightness-resolved getter is the vivid amber on
   dark, so the hue only moves where it has to. (The palette weakness is pre-existing and
   left alone elsewhere; this spec only fixes what it ships.)
3. **The unread count uses `inkOn(cs, fill)`**, the measuring helper from `pr_tone.dart`:
   `cs.surface` on the amber pill is ~2.1:1. A one-line toast was also 57 pt tall until the
   icon buttons opted out of the theme's 48 pt tap padding (`shrinkWrap`, 32 pt targets).

**D11 — The phone has no room for the bell, so the bell is not on the phone's bar.** Four
glass circles plus the connection chip already fill a 320 pt top bar — a fifth overflowed it
by 4 px (`worktree_row_overflow_test.dart` caught it). Activity lives in **Settings ›
Activity** on mobile, and the unread pill rides the Settings button that leads there
(`ActivityUnreadDot`). Same reasoning `docs/UX.md` §3 already applies to the message
navigator: a phone has no screen to spend on permanent chrome.

## Surfaces

**Toast** — the transient view. Title, severity stripe, count badge, a copy button when
`detail` is present, tap → Activity (or the session, when `sessionId` is set), swipe/× to
dismiss. Dismissing loses nothing.

**Activity on mobile** — **Settings › Activity** (beside Diagnostics), pushed as
`$kRouteRepos/activity`: newest first, severity filter (the Diagnostics level-filter
precedent), a row per event — severity glyph, title, `source · 4m`. Tap to expand `detail` as
a monospace `SelectableText`. Per-row copy, **Copy all**, **Clear**. Unread clears on open.

**Activity on desktop** — the sidebar-footer bell opens the same [ActivityView] in a
420 × 520 top-right dialog. A hover-anchored `OverlayPortal` popover (the `PortsPopover`
house pattern) was rejected: it is ~150 lines of positioning machinery for a third rendering
of one list, and this is a list you *read*, not a glyph you peek at.

## Non-goals

- No persistence (D9), no server round-trip: activity is a *client* record of what this
  client did and saw.
- No new OS notification triggers. SPEC-background-wake-notifications/08 decide what buzzes your phone; this spec only
  writes down what happened.
- No per-source mute/verbosity settings. Five severities and a filter are enough until a real
  source proves noisy.

## Verification

- `status_event_test.dart` — severity ordering, clipboard format, coalescing key, count text.
- `status_center_test.dart` — ring-buffer eviction at capacity, change stream, coalescing
  window (in/out of 8 s), unread count, `worstUnread`, silent posts (D7), `markAllRead`,
  `clear`, `copyAllText` order, `appLog` mirroring (D2).
- `toast_queue_test.dart` — dwell per severity (D5), max-3 + `+N` overflow, in-place update
  for a coalesced repeat, dismiss/promote.
- `status_toast_test.dart` — a post shows a toast, it leaves on its own dwell while the record
  survives, copy button only with `detail`, a silent post never toasts, tap hands the event
  to the shell.
- `activity_view_test.dart` — order, empty state, mark-read on open, live append, expand to
  selectable detail, copy-one/copy-all, filter threshold, clear, session deep link.
- `activity_bridge_test.dart` — lifecycle → severity mapping, silence, no double-posting.
- `activity_badge_test.dart` — count, 9+ cap, live lighting, read-clears, silence, tint by
  worst unread, the dot never eats its child's tap, the desktop dialog opens/reads/closes.
- `no_snackbar_test.dart` — zero `showSnackBar` in `app/lib` (D8).
- `status_lifetime_test.dart` — no `ref.status` after an `await` (D3): `ref` dies with its
  widget, and these are exactly the flows whose widget can vanish mid-action.
- `theme_contrast_test.dart` — the count clears AA on every severity fill; the glyphs clear
  the 3:1 UI floor (D10).
- `test/sim/status_sim_test.dart` — audit renders (toast light/dark, Activity phone/desktop),
  `PORTS_AUDIT=1 … --update-goldens`, gated like the ports harnesses.
- `flutter analyze --fatal-infos` clean; existing suite green (baseline recorded in the PR).
