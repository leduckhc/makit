# SPEC-21 — Chat transcript scroll anchoring (open-at-latest, load-back-on-demand)

**Status:** Proposed · **Priority:** P1 · **Branch:** `feat/chat-scrolling`
**Scope:** `app/lib/ui/session/session_screen.dart`, `app/lib/desktop/chat/desktop_chat_pane.dart`. Behavior-preserving except for the scroll/anchoring UX described below.

---

## Goal

Opening a session should land **instantly on the newest message** with no
visible top→bottom scroll and no jank, and older history should render **only as
the user scrolls up** (Messenger/iMessage model). This must not regress live
message streaming, the "working…" indicator, or the ask-user (elicitation)
dialog.

## Background — why the current version lurches

Both transcripts use a **forward** `ListView.builder` (index 0 = oldest at top)
and reach the newest message by jumping to the bottom:

- **Mobile** (`session_screen.dart:56–73`): on first load it calls
  `_jumpToBottom()` (`jumpTo(maxScrollExtent)`) then **re-jumps 4 more times** at
  60/180/360/600 ms because markdown/code/images settle their height over
  several frames and change the extent.
- **Desktop** (`desktop_chat_pane.dart:166–174`): jumps once to
  `maxScrollExtent` on every new item.

`jumpTo(maxScrollExtent)` on a forward list forces layout of **every item above
the target** to compute the extent — the opposite of lazy — and the repeated
re-jumps are the visible lurch and the lag.

**Key fact:** the full transcript is already in memory. `subscribeSession` sends
`fromSeq: 0` (`store.dart:241–260`), the server replays the entire history into
`events[sessionId]`, and `chatItemsProvider` folds all of it (`store.dart:555`).
So "load older messages" is a **rendering/scroll** concern, not a data-fetch
concern. No pagination protocol is needed.

## Design — reversed lazy list

Render the transcript with `reverse: true` and feed items **newest-first**.
`ListView.builder` stays lazy, so:

- The viewport's resting position (offset `0`) **is** the bottom/newest message.
  Opening the session shows the latest message immediately — no measuring pass,
  no re-jumps.
- Older messages are built one screen at a time **as the user scrolls up** —
  nothing above the viewport is rendered until reached. This is the
  "scroll-back-on-demand" behavior, achieved for free.
- Late-settling image/markdown heights no longer cause a jump: layout grows
  upward from the pinned bottom anchor, so the newest item stays put.

### Ordering

Reverse **locally in the widget** via an index transform; keep
`chatItemsProvider` ascending (oldest→newest) so no other consumer is affected.

For a list with the optional trailing "working…" indicator, map the reversed
index `i` to a logical position where `i == 0` is the indicator (when running)
or the newest item:

```
itemCount = items.length + (running ? 1 : 0)
// reverse:true, so i counts from the bottom (visual bottom = newest):
//   running && i == 0        -> WorkingIndicator (sits below newest message)
//   else                     -> items[items.length - 1 - (running ? i - 1 : i)]
```

### Live-message auto-scroll (do not yank)

On a **new** incoming item (`items.last.seq != _lastSeq`), only pull to the
newest if the user is already near the bottom:

```dart
const nearBottomPx = 120.0;
final atBottom = !_scroll.hasClients || _scroll.position.pixels <= nearBottomPx;
// reversed list: newest is at offset 0
if (atBottom) _scroll.animateTo(0, duration: 200ms, curve: Curves.easeOut);
```

If the user has scrolled up reading history, leave their position untouched.

**Optional (nice-to-have, not required for acceptance):** when a new message
arrives while the user is scrolled up, show a small "↓ New messages" pill that
`animateTo(0)` on tap. Ship behind the same near-bottom check; omit if it adds
meaningful complexity.

### Padding / scrims

The `ListView` `padding` (top inset + bottom composer clearance on mobile) maps
to visual top/bottom regardless of `reverse`, so the existing `EdgeInsets`
values stay the same. The top/bottom glass scrims are `Positioned` siblings and
are unaffected.

## Work items

### W1 — Mobile: reverse `session_screen.dart`

- Add `reverse: true`; apply the index transform above.
- Delete `_jumpToBottom()`, the `firstLoad` branch, and the
  `[60, 180, 360, 600]` delayed re-jump loop (`session_screen.dart:56–73, 267–271`).
- Replace the streaming `animateTo(maxScrollExtent)` with the near-bottom-gated
  `animateTo(0)`.
- Verify the "working…" indicator renders directly **below** the newest message
  (index 0 when running).

### W2 — Desktop: reverse `desktop_chat_pane.dart`

- Same `reverse: true` + index transform; each row keeps its centered
  `ConstrainedBox(maxWidth: kReadableContentMaxWidth)` wrapper.
- Replace the unconditional `jumpTo(maxScrollExtent)` (`:166–174`) with the
  near-bottom-gated `animateTo(0)`.
- `WorkingIndicator(compact: true)` becomes index 0 when running.

## Non-goals

- **Server-side windowed replay.** Streaming the whole history over WSS on
  subscribe is unchanged. If long-session *load time* (not scroll) becomes a
  problem, that is a separate protocol change (replay last N, fetch older on
  request) tracked elsewhere.
- **Elicitation / ask-user is untouched.** `SrvRequestHandler` presents the
  `AskWizard` as a modal over `MaterialApp.builder` — above the router, not an
  item in the transcript — so scroll direction/ordering does not affect it. The
  persisted `askUserQuestion` tool result is an ordinary `ChatItem` and reorders
  with everything else automatically.
- No explicit "Load 50 more" button or in-memory render cap;
  `ListView.builder`'s cache window already bounds built widgets.

## Testing

- **Widget test (mobile & desktop):** given a session with N items, the first
  frame shows the newest item and `_scroll.position.pixels` is at/near `0`
  (bottom anchor) without any post-frame jump loop.
- **Streaming, at bottom:** appending an item while at the bottom scrolls to the
  new newest item.
- **Streaming, scrolled up:** with the list scrolled up (pixels > nearBottom),
  appending an item does **not** change `_scroll.position.pixels`.
- **Working indicator:** while `SessionStatus.running`, the indicator is the
  bottom-most row (index 0) and disappears when the status clears.
- **Ordering:** items render newest-at-bottom, oldest-at-top (visual order
  identical to today).
- Regression: `flutter analyze --no-pub` and `flutter test --no-pub` pass.

## Risks

- **Index-transform off-by-one** with the trailing indicator — covered by the
  working-indicator test.
- **`animateTo(0)` vs `jumpTo(0)`** on rapid streaming: prefer `jumpTo(0)` if
  animation stacking causes visible stutter during fast token streams.
- Group/date separators (if added later) must compare in reversed order; none
  exist today.
