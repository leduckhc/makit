# SPEC-37 — Queue tray: a second presentation, and promote

**Status:** Implemented · **Priority:** P2 · **Branch:** `feat/steering-vs-queuing`
**Depends on:** SPEC-35 (the queue), SPEC-38 (edit / reorder / placements)
**Mockups:** [`mockups/mid-turn-steer-queue.html`](../../mockups/mid-turn-steer-queue.html) §C — the tray, with ⤒ promote.

**Scope:** `server/src/session.ts`, `server/src/ws/commands/session.ts`,
`server/src/protocol.ts`; app: new `app/lib/ui/composer/pending_queue_tray.dart`,
`pending_queue.dart` (one enum value + a mount-point extension),
`pending_queue_slot.dart`, `store.dart`, one settings row.

---

## Why this exists

SPEC-38 shipped variant **E** (ghost bubbles) twice — `pinned` and `inline` —
and grafted C's *edit + reorder* onto it. What it did **not** ship was variant
**C** itself: the compact tray, and the one action only the tray had —
**promote (⤒)**: *stop the current turn and send this message now*.

Interrupt was never a new capability. makit has always been able to abort a turn
(the stop button, `cancel`); what was missing was aiming it **at one queued
message** instead of at the whole queue.

## Decisions

1. **The tray replaces the bubbles; it does not accompany them.** One preference,
   one settings control, two values (`pinned` · `tray`). Two independent axes
   ("where" × "how") would be four combinations for a choice the user makes once.
2. **`inline` is gone, not kept alongside.** The queue now has exactly ONE mount
   point — above the composer — so `inlineQueueVisibleProvider`, the trailer-row
   slot and the `mountPoint` routing all disappeared with it. The transcript's
   trailer is back to what SPEC-21/34 defined: ask card or working indicator, and
   nothing that can appear while the agent is idle.
3. **The bubbles are hollow.** Same column, same shape and same corner notch as
   `ChatBubble.user`, no fill: that single difference is the whole distinction
   between "waiting to send" and "already sent". A filled bubble read as sent.
4. **The four controls are one tight 26px group.** ↑↓ used to sit on the far side
   of the text from ⤒✕, so on any message longer than a word they read as two
   unrelated pairs. Under the 44px touch minimum — a deliberate tradeoff, since a
   ghost bubble has to read as a message, and 44px boxes made it twice the height
   of the sent one.
5. **Promote is composed from primitives that already exist**: move to the head
   (`reorderQueue`), then abort (`adapter.cancel()`). Delivery still happens in
   `flushNext` on the adapter's own `idle`, so promote inherits the flush
   discipline — one message per turn, never overtaking, never doubled.
6. **Promote must not borrow `cancel`'s path.** The `cancel` *command* calls
   `clearQueue()` — stop means stop. Promote means the opposite: keep the rest.
   Sharing the code would have quietly destroyed the queue.
7. **A stale promote is a no-op, not an interrupt.** If the id is no longer
   queued (it flushed between the tap and the frame), the server acks and does
   **nothing**. Aborting a turn the user never asked to stop, on the strength of
   a tap that arrived late, destroys work — the failure mode is not symmetric
   with `queue.cancel`, where a stale id costs nothing.
8. **Promote is unavailable mid-edit.** An open editor holds text the server has
   not seen; promoting then would interrupt the turn to send the *old* text.
9. **The label states the cost.** "Stop the current turn and send this now", not
   "Send now". It is the only place the user learns what ⤒ spends.

## Wire

```
queue.promote { sessionId, queuedId }  → ack (always; a stale id changes nothing)
```

`queuedId`, not `id` — see below.

## Bug this uncovered

`Envelope.toJson()` in the app spreads the command body **after** the frame's own
fields:

```dart
Map<String, dynamic> toJson() => {'v': v, 't': t.wire, 'id': id, ...body};
```

So `queue.cancel` / `queue.update`, which carried the message id as `id`, were
overwriting the **request** id. Fire-and-forget hid it: nothing awaited those
acks, so nobody noticed the ack came back labelled with a queued message instead
of the request. All queue commands now use `queuedId`, and a store test asserts
the request id survives `toJson()`.

The general hazard — a body key shadowing an envelope key, silently — is still
there for every other command. Left alone deliberately; it wants a guard in
`Envelope`, not a rename per call site.

## What is NOT here

- **Drag to reorder.** The tray keeps ↑↓ for the same reason the bubbles do
  (SPEC-38 decision 6): both sit inside or beside a scrollable.
- **A per-message steer.** Steering is chosen by capability, not by the user
  (SPEC-35); promote is the only per-message *delivery* choice.
