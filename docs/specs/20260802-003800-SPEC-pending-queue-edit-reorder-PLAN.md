# SPEC-pending-queue-edit-reorder — Implementation plan

Spec: [`20260802-003800-SPEC-pending-queue-edit-reorder.md`](./20260802-003800-SPEC-pending-queue-edit-reorder.md)

Ground rules (AGENTS.md): failing test first, SOLID/YAGNI, surgical diffs.

## Status

| Task | State |
|---|---|
| T1 `updateQueued` / `reorderQueue` on the session | ✅ done — 3 tests |
| T2 `queue.update` / `queue.reorder` commands | ✅ done — 5 tests |
| T3 `PendingQueue` + `PendingBubble` (shared widget) | ✅ done — 9 tests |
| T4 placement preference + `PendingQueueSlot` | ✅ done — 6 tests |
| T5 four mount points (2 surfaces × 2 slots) | ✅ done |
| T6 settings row (desktop + mobile) | ✅ done — covered by T4's move test |
| T7 live verification | ✅ done — real `pi-acp` |

**Complete.** server: 742 tests + `pnpm typecheck` clean. app: 1427 tests +
`flutter analyze` clean.

## Live verification (real `pi-acp`, real `Session`)

```
status: running
queued: [ 'say APPLE', 'say BANANA' ]
after edit + reorder: [ 'say BANANA', 'say APRICOT instead' ]
delivered: ["Count from 1 to 60…","say BANANA","say APRICOT instead"]
PASS: edited text delivered, in the reordered order
```

## Deviations

1. **The trailer row hosts the inline queue — no synthetic transcript items.**
   The spec anticipated "synthetic items in `foldEvents` or a second trailer"; the existing
   trailer turned out to be enough, which is what made `inline` affordable. Consequence:
   `hasTrailer` must also be true when an inline queue is non-empty
   (`inlineQueueVisibleProvider`), otherwise the row — and every index shifted by it in
   `transcriptChildIndexFinder` — would vanish the moment the agent went idle with messages
   still pending.
2. **The slash palette needed no `Overlay`/`LayerLink` after all.** I had argued it would
   (and used it as an argument against `inline`). Wrong: the composer already renders
   `SlashPalette` as a plain `Column` child, and the editor does the same, so the palette
   scrolls with its own field and cannot be anchored to a recycled row. The spec records the
   corrected reasoning.
3. **`Composer.queued`/`onCancelQueued` were replaced by a single `pendingQueue` widget
   slot**, and SPEC-mid-turn-steering-and-queue's `queued_chips.dart` was deleted. The composer no longer knows the
   queue's commands, which is exactly what lets the *same* widget mount in the transcript.
   (Deleting my own SPEC-mid-turn-steering-and-queue code, not someone else's.)
4. **A "dashed" border is not a thing in Flutter.** The ghost bubble uses a dimmed outline
   (`outlineVariant`) with a transparent fill, which reads as "not sent yet" without a
   custom painter. If it turns out to be too subtle next to a real bubble, a
   `CustomPainter` dash is a contained follow-up.
5. **Reorder is ↑↓ only** (spec decision 6), so the mockup's drag handle is not shipped.
   Both placements sit inside or beside a scrollable and drag would fight the scroller; the
   buttons also give desktop keyboard users a path the drag never would.
6. **`queue.update` sends the text even when unchanged is skipped client-side.** The bubble
   compares against the original before dispatching, so tapping into a message and tapping
   out is not a wire round-trip.

## Follow-ups (not built)

- Drag-to-reorder on desktop, where the scroll conflict is weaker.
- A "this was just sent" toast when a message flushes while its editor is open (today the
  bubble simply disappears and the edit is a no-op ack — honest, but abrupt).
- Attachment thumbnails on a pending bubble; today it shows a paperclip + count.
