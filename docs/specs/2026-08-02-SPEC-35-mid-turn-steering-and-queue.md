# SPEC-35 — Mid-turn messages: steer vs queue

**Status:** Proposed · **Priority:** P2 · **Branch:** `feat/mid-turn-steering`
**Depends on:** SPEC-27 (adapter set: `pi` over `pi-acp`, `codex` over `app-server`), SPEC-29 (turn lifecycle), SPEC-33 (`send.message attachments[]`)
**Prerequisite landed:** commit `87b4941` — `turn/started` is the only source of truth for entering a turn (see [§Evidence](#evidence--what-the-agents-actually-do)).

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

| Condition | Message |
|---|---|
| stale/incorrect precondition | ``expected active turn id `turn_stale_0000` but found `019fc477-99ed…` `` |
| no turn in flight | `no active turn to steer` |
| review / compact turn | `activeTurnNotSteerable` (`NonSteerableTurnKind = review \| compact`, from the binary; not exercised live) |

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
   never delivered. Pending state travels as a separate, non-historical event
   ([§Wire](#wire-protocol)).
7. **Attachments are materialised at delivery time, not at enqueue time.** `prepareTurn`
   writes files into the worktree (SPEC-33); doing that for a message that may be
   cancelled would litter the tree. The `mediaId`s are durable in the content-addressed
   store, so deferring is safe.
8. **`cancel` (stop) clears the queue.** Stop means "stop", and a queue that outlived an
   interrupt would fire the user's follow-ups into an aborted context. Removing a *single*
   pending message is the separate `queue.cancel` cmd.
9. **The queue is in-memory and per live session.** It does not survive daemon restart or
   `session.kill`; on session death, pending items are dropped and a `session.queue`
   snapshot with an empty list is emitted. Persisting unsent intent across restarts is out
   of scope.

## Server design

### Send path (`session.ts`, one decision point)

```
send.message
  ├─ adapter idle?                    -> adapter.send(input)                  (today's path)
  └─ adapter busy (hasActiveTurns)
       ├─ await adapter.steer(input)
       │     ├─ true                   -> done; the adapter echoes user.message
       │     └─ false                  -> enqueue(input); emit session.queue
       └─ (codex internal ladder, below)
```

`CodexAppServerAdapter.steer()`:

| `turn/steer` outcome | Action |
|---|---|
| result `{turnId}` | echo `user.message`, return `true` |
| `no active turn to steer` | the turn ended in the race window → return `false` **and** let the session layer treat the session as idle: the queue flush that follows on `idle` delivers it immediately |
| precondition mismatch | return `false` → queue (do **not** retry with the newly-observed id: the user's message was written against what they saw) |
| `activeTurnNotSteerable` (review/compact) | return `false` → queue |

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

```ts
// New EventKind — transient state, last-one-wins, NOT transcript history.
| "session.queue"        // payload: { pending: QueuedMessage[] }

export interface QueuedMessage {
  /** Server-assigned, stable for the lifetime of the queue entry. */
  id: string;
  text: string;
  attachments?: WireAttachment[];   // unresolved: bytes stay in the media store
  queuedAt: number;
}

// New CmdKind
| "queue.cancel"          // { sessionId, id }  -> drops one pending message
```

`session.queue` is emitted on every mutation (enqueue, cancel, flush, clear) and on
`session.attach`, so a reconnecting client gets current state without replaying. Like
`session.status` it is a snapshot, so log replay converging on the final value is correct.

## App design

- The composer stays enabled while running (unchanged). It also stays enabled while
  messages are pending.
- Pending messages render as a compact stack of **chips directly above the composer**, in
  queue order, each with an ✕ that sends `queue.cancel`. Chips are not transcript rows:
  they live in the composer's own column so they cannot perturb SPEC-21 anchoring or
  SPEC-34's index-keyed markers.
- A steered message needs **no** affordance: it arrives as a normal `user.message` event
  and appears in the transcript, which is exactly what the user expects to see.
- `session.queue` is stored on the session model (`app/lib/store/models.dart`) and
  reduced in `store.dart` next to `session.status`; `chat_items.dart` is untouched.

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
- **App:** chips render in order from `session.queue`; ✕ sends `queue.cancel`; an empty
  snapshot removes the row; a steered message shows no chip.
- **Live smoke (documented, not CI):** `/tmp/spike-steer/live-adapter.mts`-style harness
  against real `codex app-server` (mid-turn send → single turn, `BANANA` inside it,
  statuses end `idle`) and against `pi-acp` (queue flushes after `end_turn`, no
  "Starting queued message" prose in the transcript because makit never overlaps prompts).

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
- **`activeTurnNotSteerable` is untested against a live review/compact turn.** The ladder
  treats every steer failure as "queue", so an unexpected error code degrades to correct
  behaviour rather than a lost message.
