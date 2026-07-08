# SPEC-08 — Slice 1: Actionable notifications (resolve approvals from the lock screen)

**Status:** planned · ready for implementation · **Depends on:** none
**Fast-follow:** [SPEC-07](./2026-07-08-SPEC-07-background-wake-notifications.md) (force-quit wake)
**Touches (new):** `app/lib/notifications/notification_request.dart`,
`app/test/notification_request_test.dart`, `app/test/srv_request_handler_notify_test.dart`
**Touches (edit):** `app/lib/store/connection.dart`,
`app/lib/notifications/notification_service.dart`,
`app/lib/ui/widgets/srv_request_handler.dart`, `app/lib/main.dart`,
`app/test/connection_controller_test.dart`

## Goal

The daily-use loop: agent needs an approval or asks a question → phone buzzes →
user taps **Approve/Deny** (or types a **quick reply**) directly from the
notification while the app is backgrounded → the decision reaches the agent
**without opening and navigating the app**.

**Scope:** the app process is still alive (foreground, or backgrounded with a
live/recently-suspended WebSocket). Force-quit wake is **out of scope** →
SPEC-07. This plan marks the exact seam where the killed-app path plugs in.

## Data flow

```
server ReverseRpc.askDevice({kind:'confirmAction', action, sessionId})
  → srv.request { t:'srv.request', id:<requestId>, kind, action, sessionId }
  → ConnectionController.srvRequests (Stream<Envelope>)
  → SrvRequestHandler._dispatch(env)
       ├─ FOREGROUND → existing dialog (unchanged)
       └─ BACKGROUND → NotificationService.show(category, payload={sid,rid,kind})
  → user taps Approve/Deny/Reply (foreground action → app resumes, socket intact)
  → NotificationService.onDidReceiveNotificationResponse (LIVE isolate)
  → main.dart onAction: parse payload → responseForAction(kind,actionId,input)
  → ConnectionController.respondTo(requestId, body)   [idempotent]
  → srv.response { id:<requestId>, kind, approved|answers }
```

Grounded contracts:
- `srv.request` `Envelope.id` **is** the `requestId` for `respondTo`. `Envelope.decode`
  flattens body, so `env.body['kind'|'action'|'sessionId']` are directly available.
- Response shapes (verified in `server/connectors/pino-pi.ts`, `server/src/adapters/pi.ts`):
  `confirmAction` → `{kind, approved}`; `askUserQuestion` consumers read
  `resp.answers[i]` (label text), never indices → a quick reply maps to `answers:[text]`.

## Key decision: foreground actions

Make Approve/Deny/Reply **foreground** actions
(`DarwinNotificationActionOption.foreground`; Android taps on a live process
route to the running isolate). This keeps all of Slice 1 on
`onDidReceiveNotificationResponse`, which has the live `ConnectionController`
and socket. The alternative forces taps into
`onDidReceiveBackgroundNotificationResponse` — a `@pragma('vm:entry-point')`
isolate with no socket/Riverpod, i.e. the SPEC-07 problem. Building its
queue+replay now is YAGNI.

**SPEC-07 seam:** register `onDidReceiveBackgroundNotificationResponse` as a
top-level stub that only persists `{requestId, actionId, input}` to
`SharedPreferences` (key `pino_pending_actions`) and returns. Slice 1 does not
replay; SPEC-07 drains this on next launch/reconnect through the same
`responseForAction` + `respondTo` path. Mark with `// SPEC-07:`.

**Idempotency:** both the dialog path (`SrvRequestHandler._respond`) and the
notification path funnel into `ConnectionController.respondTo`. Add a
`Set<String> _respondedRequests` guard there so the second response for a
requestId is a no-op (matches the server's first-wins semantics).

## TDD steps (each independently `flutter test`-verifiable)

1. **Pure request→notification content** — NEW `notification_request.dart` +
   `notification_request_test.dart`. `notificationForRequest({kind, body, label})`
   → `RequestNotification(title, body, category)`. Tests: confirmAction →
   confirm category + action in body; askUserQuestion (wizard + single form) →
   question category + first question; input kind / unknown → null. Consts:
   `kConfirmCategoryId='pino_confirm'`, `kQuestionCategoryId='pino_question'`.
2. **Pure actionId→response body** — same file. `responseForAction({kind,
   actionId, input})`. Tests: approve→`{approved:true}`, deny→`{approved:false}`,
   reply+input→`{answers:[input], answer:input, indices:[-1]}`, reply+null→
   `answers:['']`, unknown→null. Consts: `kApproveActionId='pino_approve'`,
   `kDenyActionId='pino_deny'`, `kReplyActionId='pino_reply'`.
3. **Pure payload codec** — same file. `encodeRequestPayload({sessionId,
   requestId, kind})` / `parseNotificationPayload(raw)` → `NotificationPayload`.
   Tests: round-trip; **legacy bare sessionId** parses as sessionId-only (keeps
   status-tap routing); garbage → all null.
4. **`respondTo` idempotency** — EDIT `connection.dart` + extend `FakeTransport`
   in `connection_controller_test.dart` to record `sentEnvelopes`. Test: two
   `respondTo('r1', …)` → exactly one `srv.response` with `id=='r1'`; different
   id still sends. Impl: `if (!_respondedRequests.add(requestId)) return;`.
5. **Service: categories + actionable show** — EDIT `notification_service.dart`
   (I/O, not unit-tested). Add `DarwinNotificationCategory`s (confirm: plain
   Approve + destructive Deny; question: `.text` Reply), `notificationCategories`
   in init, `onDidReceiveBackgroundNotificationResponse` stub, `onAction`
   callback, `show(..., String? category)` setting `categoryIdentifier` +
   Android `actions`/`AndroidNotificationActionInput`.
6. **SrvRequestHandler fires notification when backgrounded** — EDIT
   `srv_request_handler.dart` + NEW widget test `srv_request_handler_notify_test.dart`.
   Make the state a `WidgetsBindingObserver` tracking `_foreground`. In
   `_dispatch`, if `!_foreground && notificationForRequest(...) != null` →
   `notificationService.show(category, payload=encodeRequestPayload(...))` and
   return (skip dialog); else existing dialog. Tests: backgrounded confirmAction
   → categorized notification + no dialog; foreground → dialog + no notification.
7. **Wire `onAction` at composition root** — EDIT `main.dart`. `onAction` parses
   payload → `responseForAction` → `respondTo(rid, body)`. Update `onTapSession`
   to decode JSON payloads via `parseNotificationPayload().sessionId` (bare
   sessionId still works).

## Test plan

- **Unit:** steps 1–3 (mapping/codec), step 4 (idempotency via FakeTransport).
- **Widget:** step 6 (background→notification vs foreground→dialog) with an
  injected fake `NotificationService`.
- **Not unit-tested (platform I/O):** step 5 registration, `onAction` branching,
  background isolate stub, step 7 wiring.
- **On-device (extend `pino-e2e-testing`):** (1) backgrounded confirmAction →
  Approve on lock screen unblocks agent; (2) askUserQuestion → Reply text →
  `answers[0]`; (3) tap action AND open dialog → exactly one response; (4)
  foreground → dialog only; (5) Android action buttons + inline reply.
  `server/connectors/pino-piano.ts piano_confirm` is a ready trigger.

## Risks / open decisions (architect recommendations)

1. **Locked-screen foreground action** may require unlock before running; truly
   silent locked Approve needs the background isolate → SPEC-07. Accept for
   Slice 1; document.
2. **Re-fire on later background transition** (request arrived foreground, user
   backgrounds without answering) is a fast-follow, not Slice 1.
3. **Quick-reply has no option index** — safe today (`answers`-based); add a
   `// contract: consumers read answers[]` note.
4. **Label source** — reuse `NotificationController.labelFor` pattern from
   `projectsProvider`/`sessionsProvider`; fall back to `body['title']` then generic.
5. **SPEC-07 queue store** — `SharedPreferences` (non-secret action queue), not
   `flutter_secure_storage`. Finalize when SPEC-07 is scoped.
