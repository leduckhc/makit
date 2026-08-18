# SPEC-mid-turn-steering-and-queue — Mid-turn messages: steer vs queue

**Status:** Proposed · **Priority:** P2 · **Branch:** `feat/mid-turn-steering`
**Depends on:** SPEC-new-session-config-at-spawn (adapter set: `pi` over `pi-acp`, `codex` over `app-server`), SPEC-session-lifecycle-resume-list-delete (turn lifecycle), SPEC-user-attachments (`send.message attachments[]`)
**Prerequisite landed:** commit `87b4941` — `turn/started` is the only source of truth for entering a turn (see [§Evidence](#evidence--what-the-agents-actually-do)).
**Mockups:** [`mockups/mid-turn-steer-queue.html`](../../mockups/mid-turn-steer-queue.html) — six interactive UX candidates for the composer side (A intent-ahead · B grace window · C queue tray · D steer seam · E ghost bubble · F split send), with the shipped behaviour as the baseline.

**Scope:** `server/src/adapters/{adapter,codex,acp,stub}.ts`, `server/src/session.ts`,
`server/src/protocol.ts`, `server/src/server.ts` (one new cmd), and in the app
`app/lib/store/{store,models,chat_items}.dart`, `app/lib/transport/protocol.dart`,
`app/lib/ui/composer/composer.dart` (+ the desktop composer mount).
No new dependencies. No storage/schema change.

---

## Goal

Today makit lets you submit a message at any time, including while the agent is
mid-turn, and then does **nothing deliberate** with it: the message is handed to the
adapter as if the session were idle, and what happens next is whatever that agent
happens to do. Make the behaviour explicit, per-agent-correct, and visible:

1. A message typed mid-turn is either **steered** into the running turn (when the agent
   has a real primitive for it) or **queued** and sent when the agent goes idle. Never
   dropped, never silently reordered, never fired as an overlapping request.
2. A queued message is **visible and cancellable** before it is sent.
3. The user's transcript shows a message as sent exactly once, at the moment it was
   actually delivered to the agent.

Non-goal: changing what the **stop** button does. Interrupt-then-resend already exists
(`cancel`) and stays as-is.

## Vocabulary

| Term | Meaning |
|---|---|
| **steer** | Inject the message into the *running* turn. The agent sees it at its next step boundary; no abort, no context loss, one turn in the transcript. |
| **queue** | Hold the message client-side (server-side, from the app's point of view) and deliver it as a fresh turn once the agent reports idle. |
| **interrupt** | Abort the active turn, then send. Already shipped as the stop button; out of scope. |

## Evidence — what the agents actually do

Measured 2026-08-02 against live binaries (raw JSON-RPC, no makit in the loop; scripts in
`/tmp/spike-steer/`, findings reproduced as unit tests in this spec's plan).

### codex `app-server` (codex-cli 0.146.0)

**A second `turn/start` mid-turn is silently coerced into a steer, and the reply lies.**

```
turn/start #1  -> turn.id = …d443     ; turn/started …d443
turn/start #2  -> turn.id = …ebb6     ; status inProgress
   items for message #2 arrive with turnId = …d443   ← the ORIGINAL turn
   turn/completed …d443
   …ebb6 is never announced and never completes (observed for 45 s)
```

The model does absorb the message (`userMessage("STOP counting…")` then
`agentMessage("BANANA")` inside turn …d443) — but the returned turn id is a **phantom**.
That is the bug fixed by `87b4941`: makit registered it and pinned the session to
`running` forever, and `cancel()` then interrupted an id the server had never heard of.

**`turn/steer` is the real primitive and behaves cleanly:**

```
-> turn/steer {threadId, input:[…], expectedTurnId: "…ae66"}
<- {"turnId":"…ae66"}                       ← same id, no phantom
   transcript: userMessage(long) → agentMessage(1..60) → userMessage(STOP…) → agentMessage(BANANA)
   all under turnId …ae66, one turn/completed
```

Failure modes (JSON-RPC errors, `code: -32600` — **not** results):

| Condition | `message` | `data.codexErrorInfo` |
|---|---|---|
| stale/incorrect precondition | ``expected active turn id `turn_stale_0000` but found `019fc477-99ed…` `` | — |
| no turn in flight | `no active turn to steer` | — |
| compact turn | `cannot steer a compact turn` | `{activeTurnNotSteerable:{turnKind:"compact"}}` |
| review turn | `cannot steer a review turn` | `{activeTurnNotSteerable:{turnKind:"review"}}` |

Both non-steerable kinds were exercised live (`thread/compact/start` and
`review/start` on a dirty worktree), which produced two findings worth more than
the confirmation itself:

- **`activeTurnNotSteerable` is not in `message`.** It lives in
  `data.codexErrorInfo`, so a ladder that string-matches the message would miss
  it. This is why the implementation keys off "the request rejected", not off the
  code — every rejection means the same thing to the caller: queue instead.
- **A review announces a different turn id than the one it treats as active.**
  `review/start` returns turn `X` (and codex considers `X` active), while
  `turn/started` announces a *different* id `Y`. Steering `Y` gives the
  precondition error naming `X`; steering `X` gives `cannot steer a review turn`.
  Either way makit queues, because it steers `activeTurnIds[0]` — the announced
  id — and treats any rejection as "queue". See [§Risks](#risks).

### pi over `pi-acp` (pi-acp 0.0.32) — and ACP generally

ACP has **no steering primitive** in v1 or in the v2 draft: v1's `session/prompt` is
request→response for the whole turn; v2 returns on *acceptance* and reports `running` /
`idle` / `requires_action` via `state_update`, and still specifies "after the Agent
reports `idle`, the Client may send another `session/prompt`".

pi does not reject an overlapping prompt — it **queues internally**:

```
prompt #1 -> {"stopReason":"end_turn"}
prompt #2 -> {"stopReason":"end_turn"}   (settles 26.6 s later, i.e. after #1)
stream: "…60 — The base of Babylonian mathematics…"
        "Starting queued message. (0 remaining)"     ← arrives as agent_message_chunk
        "BANANA"
```

Two conclusions: makit currently gets away with overlapping ACP prompts **by luck**, on
one agent, and pi's queue notice lands in the transcript as agent prose. Any other ACP
agent may legitimately error instead.

## Decisions

1. **Steer where the agent has a primitive; queue everywhere else.** codex steers
   (`turn/steer`); ACP agents queue. This is the smallest change that is correct on both:
   codex already steers implicitly today, so steering is not a behaviour regression, and
   ACP gains a queue instead of relying on undocumented agent tolerance.
2. **No user-facing mode setting** (no `/queue steer|interrupt` à la OpenClaw). One
   behaviour per transport, chosen by capability. Rejected alternatives in [§Rejected](#rejected-alternatives).
3. **`turn/started` is the only source of truth for "a turn is in flight"** — landed in
   `87b4941`. Every decision below reads `TurnStatusTracker.hasActiveTurns` /
   `activeTurnIds`; nothing infers in-flight state from a request reply.
4. **The queue lives in the server's session layer, not in the adapter.** The adapter
   grows exactly one method:

   ```ts
   /** Inject `input` into the running turn. False = this agent cannot steer now. */
   steer(input: UserInput): Promise<boolean>;   // SubprocessAdapter default: false
   ```

   Base returns `false`, codex overrides. One queue implementation, one flush policy, one
   set of tests — instead of the per-adapter drift that `TurnStatusTracker` was created to
   kill.
5. **FIFO, one turn per queued message.** Queued messages are not coalesced into a single
   prompt: each was a separate user intent and each must appear as its own
   `user.message`. (Coalescing is a cost optimisation nobody asked for.)
6. **A queued message is not in the event log until it is sent.** The transcript echo
   still comes from the adapter at delivery time (`user.message`, as today), so a
   cancelled queue item leaves no trace and a replayed log never shows a message that was
   never delivered. Pending state travels as `SessionDTO.queued` on the sessions snapshot
   ([§Wire](#wire-protocol)).
7. **Attachments are materialised at delivery time, not at enqueue time.** `prepareTurn`
   writes files into the worktree (SPEC-user-attachments); doing that for a message that may be
   cancelled would litter the tree. The `mediaId`s are durable in the content-addressed
   store, so deferring is safe.
8. **`cancel` (stop) clears the queue.** Stop means "stop", and a queue that outlived an
   interrupt would fire the user's follow-ups into an aborted context. Removing a *single*
   pending message is the separate `queue.cancel` cmd.
9. **The queue is in-memory and per live session.** It does not survive daemon restart or
   `session.kill`; on session death, pending items are dropped and an empty `queued` field
   is published in the sessions snapshot. Persisting unsent intent across restarts is out
   of scope.

## Server design

### Send path (`session.ts`, one decision point)

```
send.message
  ├─ adapter idle?                    -> adapter.send(input)                  (today's path)
  └─ adapter busy (hasActiveTurns)
       ├─ await adapter.steer(input)
       │     ├─ true                   -> done; the adapter echoes user.message
       │     └─ false                  -> enqueue(input); publish sessions snapshot
       └─ (codex internal ladder, below)
```

`CodexAppServerAdapter.steer()`:

| `turn/steer` outcome | Action |
|---|---|
| result `{turnId}` | echo `user.message`, return `true` |
| `no active turn to steer` | the turn ended in the race window → return `false` **and** let the session layer treat the session as idle: the queue flush that follows on `idle` delivers it immediately |
| precondition mismatch | return `false` → queue (do **not** retry with the newly-observed id: the user's message was written against what they saw) |
| `activeTurnNotSteerable` (review/compact) | return `false` → queue. Verified live via `thread/compact/start` (announced id = active id, so the adapter really does receive this error) and via `review/start` (where the announced id differs, so the adapter receives the precondition error instead — same outcome) |

### Flush

`TurnStatusTracker` already emits `idle` exactly once when everything settles. The session
layer subscribes: on `idle`, if the queue is non-empty, shift one item, `adapter.send()` it,
emit the new `session.queue` snapshot. One item per idle transition — the next flush is
driven by the next `idle`, so the loop cannot outrun the agent.

Ordering guarantee: while the queue is non-empty the session is either running or
flushing, so a *new* `send.message` must append to the queue rather than jump ahead — the
busy check in the send path covers this, except for the window between `idle` and the
flush's `turn/started`. The queue therefore takes priority: **if the queue is non-empty,
enqueue** (checked before the busy check).

### Wire protocol

> **Amended during implementation.** The queue was originally specified as a
> `session.queue` event kind. It ships on the **sessions snapshot** (`SessionDTO.queued`)
> instead — see [PLAN deviation 1](./20260802-003500-SPEC-mid-turn-steering-and-queue-PLAN.md#deviations): an event
> kind is persisted in the durable log, so a restart would replay a stale non-empty queue
> as ghost chips for messages the server no longer holds.

```ts
// protocol.ts — on SessionDTO, so it rides the existing sessions snapshot
// (already reconnect-safe, already broadcast on `metaChanged`).
queued: QueuedMessageDTO[];

export interface QueuedMessageDTO {
  /** Server-assigned, stable for the lifetime of the queue entry. */
  id: string;
  text: string;
  queuedAt: number;
  /** A count, not descriptors: the chip only needs to say "and an image". */
  attachmentCount?: number;
}

// New CmdKind
| "queue.cancel"          // { sessionId, id }  -> drops one pending message
```

A `queue.cancel` naming an id the server no longer holds **acks** rather than
errors: the message flushed between the tap and the frame, which is a race the
user cannot avoid.

## App design

- The composer stays enabled while running (unchanged). It also stays enabled while
  messages are pending.
- Pending messages render as a compact stack of **chips directly above the composer**, in
  queue order, each with an ✕ that sends `queue.cancel`. Chips are not transcript rows:
  they live in the composer's own column so they cannot perturb SPEC-chat-scroll-anchoring anchoring or
  SPEC-message-navigator's index-keyed markers.
- A steered message needs **no** input affordance, but it does need to *say so*: the echo
  carries `payload.steered === true` and the bubble is captioned
  **"Steered into the running turn"** (same pattern as SPEC-user-attachments's sent-as-a-file note).
  Steering vs queueing is chosen by the transport, not by the user, so the transcript is
  the only honest place to teach the difference — see
  [§Why one send button](#why-one-send-button).
- **No optimistic bubble while the agent is busy.** The optimistic user bubble guesses
  `cursor + 1` for its seq, which only holds when the very next server event is our own
  echo. Mid-turn that seq belongs to the agent's stream, so the bubble would advance the
  cursor past a real event and the reducer would drop it (`reduceEvent`'s idempotency
  guard). The queue chip is the feedback instead. See
  [PLAN deviation 2](./20260802-003500-SPEC-mid-turn-steering-and-queue-PLAN.md#deviations).
- `queued` is carried on the session model (`app/lib/store/models.dart`) and decoded in
  `transport/codec.dart` next to the rest of the DTO; `chat_items.dart` is untouched.

## Testing

Keyless and deterministic, per `makit-verify-feature-end-to-end`:

- **Adapter (codex, fake transport):** the four `turn/steer` outcomes from
  [§Evidence](#evidence--what-the-agents-actually-do) map to `true`/`false` as tabulated;
  a mid-turn send emits exactly one `turn/steer` and zero extra `turn/start`.
- **Adapter (acp/stub):** `steer()` resolves `false` without touching the wire.
- **Session layer:** enqueue while busy; one flush per `idle`; FIFO across three items;
  `queue.cancel` removes the right item and emits a snapshot; `cancel` empties the queue;
  a queued message produces its `user.message` **only** at flush; attachments are
  materialised at flush (assert no file in the worktree while pending).
- **App:** chips render in order from `SessionDTO.queued`; ✕ sends `queue.cancel`; an empty
  snapshot removes the row; a steered message shows no chip.
- **Live smoke (documented, not CI):** `/tmp/spike-steer/live-adapter.mts`-style harness
  against real `codex app-server` (mid-turn send → single turn, `BANANA` inside it,
  statuses end `idle`) and against `pi-acp` (queue flushes after `end_turn`, no
  "Starting queued message" prose in the transcript because makit never overlaps prompts).

## Why one send button

The composer is **identical** in both modes: one send button, enabled while the agent
works, no mode picker and no second "queue" gesture. What differs is the feedback:

| | steered (codex) | queued (ACP) |
|---|---|---|
| Immediate feedback | the user bubble appears as soon as `turn/steer` is accepted (makit emits the echo itself) | the chip appears instantly, before anything reaches the agent |
| Bubble caption | "Steered into the running turn" | none — it is an ordinary message once delivered |
| Undo | none: accepted is accepted | ✕ on the chip, until it flushes |

The asymmetry is real: the same keystroke has two consequences, chosen by which agent the
session runs. The *cheap, honest* resolution won — caption the outcome so the user learns
the behaviour from their own transcript, instead of requiring them to predict it. An
explicit "Queue instead" affordance would need a `send.message` `mode` flag **and** a new
steering capability on `SessionDTO` (otherwise the button is a lie on ACP sessions) **and**
a second gesture on two surfaces — deferred until someone actually wants to hold a message
back on codex.

**Next two candidates**, both mocked up in
[`mockups/mid-turn-steer-queue.html`](../../mockups/mid-turn-steer-queue.html):

1. **Intent-ahead composer (A)** — while the agent works, the placeholder, the send glyph
   and a one-line hint say what pressing send will do ("Steer the current turn… / no undo"
   vs "Queue a message… / cancellable"). Attacks the actual defect: the user cannot predict
   an irreversible action. Needs only a `steering` capability on `SessionDTO`.
2. **Grace window (B)** — hold a steer for ~3 s as an ordinary pending chip with a draining
   ring, so an accidental steer can be pulled back into the composer. Converts steering's
   one genuinely bad property into a recoverable one and reuses the queue verbatim.

The mockup also recorded two candidates as deliberately **not** planned: a queue tray with
reorder/edit (speculative until queues exceed one message) and a ghost bubble in the
transcript tail (buys elegance by touching SPEC-chat-scroll-anchoring anchoring — exactly what chips avoid).

**Both were subsequently built**, and the reasoning above did not survive contact: the ghost
bubble in SPEC-pending-queue-edit-reorder (which found the trailer row already paid for the anchoring cost) and the
tray in SPEC-queue-tray-and-promote (whose ⤒ promote turned out to be the one queue action nothing else offered).
This paragraph is kept rather than deleted because the *shape* of the misjudgement is worth
seeing: both were dismissed as speculative UI, and both earned their place by exposing a
behaviour — not a look — that the chips could not express.

## Rejected alternatives

1. **Per-session steer/queue/interrupt mode setting.** Three modes × two transports of
   which only one can steer = a matrix the user has to learn to get correct behaviour that
   capability detection can pick for them. Revisit only if users ask.
2. **Emulating steering on ACP by cancel + resend with the message appended.** Discards
   in-flight tool work and rewrites history; strictly worse than waiting for `idle`.
3. **Relying on pi's internal queue for ACP.** It works today on one agent, is
   unspecified, and leaks queue prose into the transcript as agent output.
4. **Retrying `turn/steer` with the turn id from the precondition error.** The user aimed
   their message at the turn they could see; silently redirecting it into a turn that
   started afterwards is a different action than the one they took.
5. **Persisting the queue across daemon restarts.** Unsent intent going stale in a file is
   worse than losing it while the user is present to retype it.

## Risks

- **Steering is not cancellable once accepted** (a real complaint about codex's own UI).
  This spec inherits that: chips exist only for queued messages. Mitigation is honesty —
  a steered message appears in the transcript immediately, so the user knows it landed.
- **Agents that reject overlapping prompts** are handled by construction (makit never
  overlaps after this spec), which also means the ACP path loses pi's internal-queue
  behaviour. Net: one queue, ours, visible.
- **A review turn's announced id is not codex's active turn id** (see
  [§Evidence](#codex-app-server-codex-cli-01460)). For steering this is harmless — both
  ids lead to a rejection and therefore to the queue — but it means
  `TurnStatusTracker.activeTurnIds` would hold the inner id during a review, so
  `cancel()` would `turn/interrupt` the id codex does not consider active. **Not fixed
  here and not currently reachable**: makit has no way to start a review or a compact turn
  (no `review/start`, and `/compact` is not mapped for codex). It becomes real the day a
  review/compact action is added, and should be handled then — with a live probe, not an
  assumption.
