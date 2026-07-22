# SPEC-25 — Ask-user question inline in the chat (not a modal drawer)

**Status:** Proposed · **Priority:** P2 · **Branch:** `feat/ask-user-in-chat`
**Scope (app-only):** `app/lib/store/` (new `elicitation.dart`), `app/lib/ui/widgets/srv_request_handler.dart`, `app/lib/ui/session/` (new ask-card widget + transcript wiring), `app/lib/ui/session/session_screen.dart`, `app/lib/desktop/chat/desktop_chat_pane.dart`, composer. No server/protocol change. Mockup: `mockups/ask-user-in-chat.html`.

---

## Goal

Render a live `askUserQuestion` elicitation **inline in the transcript**, anchored
where the agent asked, instead of the blocking modal `AskWizard`. The question
scrolls with history, keeps prior context visible, and — once answered — folds
into the existing persisted `askUserQuestion` tool row.

Only `askUserQuestion` moves inline. `confirmAction`, `input`, and generic
`srv.request` kinds stay as modal dialogs (out of scope).

## Locked UX decisions

1. **Resolved state = fold to a one-liner.** After answering, the inline card is
   removed; the already-persisted `askUserQuestion` `ToolCallItem` represents it
   as a collapsed tool row (`_AskUserQuestionRenderer` + the SPEC-24 fold). No new
   resolved widget is needed.
2. **Composer paused while awaiting**, with a hint ("Answer the question above…").
   The ask card offers a **"Type a different answer"** affordance; choosing it
   switches the session into *free-text answer mode* — the composer is re-enabled
   and its next submit is sent as the answer (via `respondTo`), not a normal
   message. Free-text is supported for **single-question** asks only.
3. **Always Submit.** Even single-select requires an explicit Submit (no
   answer-on-tap); multi-select shows checkboxes + Submit; multi-question shows a
   `n / N` stepper with Back/Next, Submit on the last step.

## Background — current wiring (real code)

- Elicitations arrive as `srv.request` envelopes on
  `ConnectionController.srvRequests` (`connection.dart:153`), **separate** from the
  session event stream — they are *not* `ChatItem`s. Each carries `body.sessionId`,
  `body.kind`, `body.questions` (or single-question fields), and the envelope `id`
  is the requestId.
- `SrvRequestHandler` (`srv_request_handler.dart`) is the single subscriber. For
  `askUserQuestion` it shows `AskWizard` as a modal over the app Navigator;
  responds via `respondTo(id, {indices, answers})`. `responded` (`connection.dart:160`)
  emits the id once answered (also used by the notification path).
- Mobile backgrounded requests are diverted to an **actionable notification**;
  desktop shows the dialog immediately and fires a **reminder notification** after
  `reminderDelay`.
- After the answer round-trips to the agent, the tool completes and a persisted
  `askUserQuestion` `ToolCallItem` (with `details: {indices, answers}`) is folded
  into the transcript and rendered by `_AskUserQuestionRenderer`.

## Design

### New: elicitation store (`app/lib/store/elicitation.dart`)

Passive per-session state for pending inline asks — it does **not** subscribe to
the socket itself; `SrvRequestHandler` remains the single dispatcher and pushes
into it.

```dart
class PendingAsk {
  final String requestId;
  final String sessionId;
  final List<Map<String, dynamic>> questions; // normalised wizard form
  final bool freeText; // user chose "type a different answer" (single-question only)
}

// Notifier keyed by sessionId; exposes:
//   pendingAskProvider(sessionId) -> PendingAsk?
// Methods (called by SrvRequestHandler + the AskCard/composer):
//   add(PendingAsk)
//   enableFreeText(requestId)
//   submit(requestId, {indices, answers})  -> connection.respondTo(...) then remove
//   cancel(requestId)                       -> respondTo(SrvResponse.cancelled) then remove
// Listens to connection.responded to remove entries answered elsewhere
// (notification / another surface), so the inline card disappears in sync.
```

### `SrvRequestHandler` change (surgical)

In `_presentDialog`, for `kind == 'askUserQuestion'` **when it would show the
in-app dialog** (foreground mobile, or desktop), route to the store instead of
`_showAskUserQuestion`:

```
elicitationController.add(PendingAsk(requestId, sessionId, questions));
```

Unchanged: the background→notification diversion (mobile), the desktop reminder
timer, and `_onResponded` cleanup. `confirmAction` / `input` / generic keep their
modals. The `AskWizard` widget stays (still used as the debug/test entry and any
non-inline fallback) — no deletion.

### Inline ask card (`app/lib/ui/session/ask_card.dart`)

A `ConsumerStatefulWidget` rendering a `PendingAsk` (matches the mockup):

- Accent-tinted card: question icon + optional `header` kicker + question text.
- Options as tiles (reuse the `AskWizard._OptionTile` look): radio (single) /
  checkbox (multi), `Recommended` badge, description.
- Multi-question: `n / N` stepper, Back/Next, Submit on last step; local picks
  per question, canonical `{indices, answers}` on submit (mirror `AskWizard._next`).
- Footer: **Submit** (enabled once the current step has a pick) + a **"Type a
  different answer"** text button (single-question only) → `enableFreeText`.
- On submit → `elicitationController.submit(requestId, indices, answers)`.

The card is not a `ChatItem`; each surface renders the session's `PendingAsk`
(when present) as a **trailing transcript row**, in the reversed list at the
newest position (where the running/working indicator would sit — a session
awaiting input is not running, so they don't collide).

### Composer pause + free-text mode

- While `pendingAskProvider(sessionId) != null` and **not** `freeText`: the
  composer is disabled with the hint "Answer the question above to continue…".
- When `freeText` is on: composer is enabled; its submit routes to
  `elicitationController.submit(requestId, indices: [-1], answers: [text])`
  instead of `sendMessage`, then clears. (Single-question only.)
- Wiring: the composer reads `pendingAskProvider` for its session and branches in
  its send handler; the two send sites are `session_screen.dart` and
  `desktop_chat_pane.dart` (`_send`).

## Work items

1. **W1 — Elicitation store** (`store/elicitation.dart`): `PendingAsk` + Notifier +
   providers; subscribe to `responded` for removal; `respondTo` via connection.
2. **W2 — Dispatcher** (`srv_request_handler.dart`): route foreground/desktop
   `askUserQuestion` into the store instead of the modal; keep everything else.
3. **W3 — Ask card** (`session/ask_card.dart`): the inline widget (single/multi/
   stepper/free-text), submitting canonical `{indices, answers}`.
4. **W4 — Transcript wiring**: render the session's `PendingAsk` as the trailing
   row in `session_screen.dart` and `desktop_chat_pane.dart`.
5. **W5 — Composer**: disable + hint while awaiting; free-text mode routes submit
   to the store.

## Non-goals

- No change to `confirmAction`, `input`, or generic `srv.request` (stay modal).
- No new resolved/answered widget — decision #1 reuses the persisted folded tool
  row (`_AskUserQuestionRenderer`).
- No free-text for **multi-question** asks (option selection required there).
- No server/protocol/notification-payload change; mobile background notifications
  and desktop reminders are untouched.
- `AskWizard` is retained (debug/test entry + fallback), not deleted.

## Testing

- **Store:** adding a `PendingAsk` exposes it via `pendingAskProvider`; `submit`
  calls `respondTo` with canonical `{indices, answers}` and removes it; a
  `responded` event for the id removes it (answered elsewhere); `enableFreeText`
  flips the flag.
- **Ask card (widget):** single-select requires Submit (tap alone doesn't answer);
  multi-select toggles + Submit sends joined answers; multi-question steps with
  Back/Next and submits on the last step; "Type a different answer" calls
  `enableFreeText`.
- **Transcript:** a pending ask renders as the trailing row on both surfaces;
  disappears after submit; the persisted answered tool row remains as history.
- **Composer:** disabled with hint while awaiting; enabled in free-text mode; a
  free-text submit routes to the store (not `sendMessage`).
- `flutter analyze --no-pub` clean; `flutter test --no-pub` green; `dart format`.

## Risks

- **Double-handling** between `SrvRequestHandler` and the store — mitigated by
  keeping the handler the single socket subscriber; the store is passive state.
- **Background/notify parity:** an ask answered from a notification must clear the
  inline card — covered by the store's `responded` subscription.
- **Free-text ambiguity** for multi-question — avoided by restricting free-text to
  single-question asks.
- **Trailing-row vs working-indicator collision** — a session awaiting input is
  not `running`, so only one trailing row shows; assert in tests.
- **Answered-history dependency:** decision #1 relies on the persisted tool row
  arriving. If an adapter ever answers without emitting the tool result, the
  transcript would show no trace; acceptable for now (all current adapters emit it).
```
