# SPEC-pending-queue-edit-reorder — Pending queue: editable, reorderable, two placements

> **Superseded in part by SPEC-queue-tray-and-promote.** The `inline` placement described below — the
> queue rendered inside the transcript's trailer row — was **removed**: it was the
> only placement that had to touch SPEC-chat-scroll-anchoring's anchoring and SPEC-message-navigator's index map,
> and a queue that scrolls out of view is a queue you forget you armed. The
> preference now chooses between hollow ghost bubbles and the compact tray, both
> above the composer. Everything about editing, reordering and the slash palette
> still stands, and the trailer-row reasoning is kept because it is why `inline`
> looked cheap.
>
> **Renumbered from SPEC-computer-use.** `main` landed a different SPEC-computer-use (computer use,
> `20260804-003600-SPEC-computer-use.md`) while this branch was open, so two specs
> claimed the number and every `SPEC-computer-use` in the code was ambiguous. This one moved
> because it had fewer references outside the branch.

**Status:** Proposed · **Priority:** P2 · **Branch:** `feat/pending-queue-ui`
**Depends on:** SPEC-mid-turn-steering-and-queue (the queue itself), SPEC-chat-scroll-anchoring (reversed anchored transcript + trailer row), SPEC-message-navigator (index-keyed navigator), SPEC-new-session-config-at-spawn (`session.commands`)
**Mockups:** [`mockups/mid-turn-steer-queue.html`](../../mockups/mid-turn-steer-queue.html) §G — both placements, interactive, with the slash palette in the editor.

**Scope:** `server/src/session.ts`, `server/src/ws/commands/session.ts`, `server/src/protocol.ts`;
app: new `app/lib/ui/composer/pending_queue.dart`, `app/lib/ui/composer/slash_palette.dart`
(one flag), `app/lib/store/prefs/{preference_entries,preferences_providers}.dart`,
`app/lib/store/store.dart`, the two composer mounts, the two transcript trailers, and one
settings row per surface.

---

## Goal

SPEC-mid-turn-steering-and-queue ships a pending message as a read-only chip you can only cancel. Make it a real
draft you can work on while the agent finishes:

1. **Edit** a pending message in place, with the **slash palette** — it is a composer field,
   not a label.
2. **Reorder** pending messages, because the order you thought of them is not always the
   order they should run in.
3. **Choose where they live**: `pinned` above the composer, or `inline` at the end of the
   transcript. Both ship; a preference picks (SPEC-message-navigator precedent).

## Decisions

1. **Ghost bubbles, not chips.** A pending message renders as a dashed, right-aligned
   bubble in the conversation's own column — it looks like the message it will become.
   Caption: `sends next · 1 of 3` / `then · 2 of 3`.
2. **Two placements, one widget.** `PendingQueue` is placement-agnostic and mounted twice:
   in the composer column (`pinned`) or inside the transcript's **trailer row**
   (`inline`). Default `pinned` — the safe floor, and the queue stays visible when scrolled
   up.
3. **Inline rides the existing trailer, not synthetic items.** SPEC-chat-scroll-anchoring's trailer already
   occupies index 0 of the reversed list and SPEC-message-navigator's key→index map already shifts for it
   (`hasTrailer`). Nothing goes into `foldEvents`, so no fake events, no anchoring change,
   no navigator drift. *This is what makes `inline` affordable at all.*
4. **The slash palette is a sibling widget, not an overlay.** The composer already renders
   `SlashPalette` as a `Column` child; the editor does the same. In `inline` the editor
   sits in the trailer at the visual bottom of the transcript, so a sibling palette scrolls
   with its field and can never be anchored to a recycled row. No `LayerLink`, no
   `Overlay`.

   *This corrects the mockup's notes, which argued the palette would need
   `LayerLink` + `CompositedTransformFollower` inside the lazy list and treated that as
   evidence against `inline`. It does not: the palette never needed an overlay.*
5. **Agent commands only in the editor's palette.** `/cancel`, `/new`, `/model`, `/unpair`,
   `/compact`, `/name`, `/ask`, `/help` are **client** commands: `handleClientCommand`
   intercepts them app-side and runs them *immediately* — they never reach the server as
   text. Inside a message that sends *later* they cannot mean anything, so offering them
   would promise behaviour the send path does not implement. `SlashPalette` grows one flag
   (`includeBuiltins`, default `true` so the composer is unchanged).
6. **Reorder is ↑↓, not drag.** Both placements live inside or next to a scrollable, and on
   a phone a drag gesture there fights the scroller. Two buttons work identically on both
   surfaces, are reachable by keyboard on desktop, and need no gesture arbitration. Drag is
   a later refinement, not a requirement.
7. **Edit is a full replace, cancel-on-empty.** Committing empty text is a cancel (the user
   cleared it), because a blank pending message is not a thing.
8. **The queue stays out of the event log** (SPEC-mid-turn-steering-and-queue decision 6). Editing a pending message
   therefore leaves no trace either — the transcript records what was *delivered*.

## Wire protocol

```ts
// New CmdKinds — both operate on the in-memory FIFO from SPEC-mid-turn-steering-and-queue.
| "queue.update"    // { sessionId, id, text }   -> replace text; empty text = cancel
| "queue.reorder"   // { sessionId, ids: string[] } -> new order
```

`QueuedMessageDTO` is unchanged. Both commands ack and re-broadcast the sessions snapshot
via `metaChanged`, like `queue.cancel`.

**Race rules** (the queue can flush between a tap and the frame arriving):

- `queue.update` with an unknown id → ack, no-op. The message was delivered already.
- `queue.reorder` with `ids` that do not match the current queue → apply as a *hint*:
  known ids take the given order first, ids the client did not mention keep their relative
  order after them, unknown ids are ignored. Never an error, never a lost message.

## App design

```
PendingQueue(sessionId, queued, commands)      // shared, placement-agnostic
  └── _PendingBubble  ×N
        ├── ↑ ↓        reorder     -> queue.reorder
        ├── text       tap to edit -> TextField + SlashPalette(includeBuiltins: false)
        ├── ✕          cancel      -> queue.cancel
        └── caption    "sends next · 1 of 3"
```

- **Placement** comes from `pendingQueuePlacementProvider` (shared `store/prefs`, read by
  both surfaces — unlike SPEC-message-navigator's desktop-only navigator, a phone is exactly where a
  queue matters).
- **`pinned`** replaces SPEC-mid-turn-steering-and-queue's chip strip in the composer column.
- **`inline`** renders inside the trailer, above the working indicator, below an inline ask
  (an ask outranks everything: it blocks the composer).
- Editing does **not** disable the composer: you can still type a new message while
  editing a pending one. Two fields, two jobs.

## Settings

- Desktop: a row in **Settings › Agents & Chat**, next to the message navigator leaf —
  segmented `Above the composer` / `In the transcript`, with a one-line blurb naming the
  tradeoff ("in the transcript, pending messages scroll away with the conversation").
- Mobile: the same segmented control in the phone's settings, in the chat section.
- No third `off` value: the queue must always be visible somewhere, or a message would be
  pending with no way to see or cancel it.

## Testing

- **Server:** `queue.update` replaces text / empty cancels / unknown id acks;
  `queue.reorder` applies a full order, tolerates partial and unknown ids, preserves
  unmentioned entries; both emit a snapshot; a flush after an edit delivers the *edited*
  text.
- **App (widget):** bubbles render in order with captions; ↑↓ reorder and dispatch the new
  id order; tap-to-edit shows a field; `/` opens the palette; the palette contains agent
  commands and **not** `/cancel`; Enter commits and dispatches `queue.update`; empty commit
  dispatches `queue.cancel`; ✕ cancels.
- **App (placement):** `pinned` puts the queue in the composer column and *not* in the
  transcript; `inline` the reverse; an inline ask still wins the trailer; switching the
  preference moves it with no other change.
- **Live:** pi/ACP session, queue two messages, edit one (with a slash command), reorder,
  let the agent go idle → the edited text is delivered in the chosen order.

## Risks

- **`inline` hides the queue when you scroll up.** Accepted: that is the tradeoff the
  preference exists to let the user choose. `pinned` is the default for that reason.
- **Two "newest message" places on screen in `pinned`** while the agent streams. Mitigated
  by the dashed/ghost treatment: pending messages never look delivered.
- **An edited message is not what the user saw when they typed it.** If a message flushes
  while its editor is open, the edit is discarded (unknown id → no-op ack) and the bubble
  disappears mid-edit. Honest but abrupt; a "this was just sent" toast is deferred.
