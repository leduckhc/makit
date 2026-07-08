# Slice 1 TDD Plan: Approval Loop End-to-End

**Architect's scope** (July 8, 2026) — approval loop wiring: server emits `srv.request`, app renders approval UI, user resolves, agent continues.

## Architecture Decisions

### 1. Where does awaiting-approval detection live?

**Decision:** In the pi adapter's `askUser` callback → the adapter already owns the UI request interception.

**Rationale:**
- Pi emits `ui.select`, `ui.confirm`, `ui.input` events; the adapter's `askUser` callback intercepts them.
- The session manager **should not** peek at adapter internals to detect "approval" — that's SRP violation.
- The adapter already threads the `askUser` callback from `Session.spawn(askUser)`. Emit `srv.request` right there.
- Keeps approval logic in one place: pi.ts, not sprayed across session.ts + manager.ts.

### 2. Does one pending approval block other messages?

**Decision:** Yes, serialize approvals (like the CLI does in `attach.ts`).

**Rationale:**
- Pi's concurrent UI requests (e.g., two `ui.select` calls) should not race. Each `askUser` call blocks the next.
- The CLI already does this (`promptChain` serialization in `attach.ts:122`).
- Simple, idempotent, prevents message order confusion.
- If parallelism is needed later, it's a refactor, not a breaking change.

### 3. Should approval timeout reset the session or just clear the UI?

**Decision:** Timeout clears the notification and rejects the `askUser` promise; pi handles the rejection (usually cancels the tool, emits error).

**Rationale:**
- Server-side timeout is already wired in `reverse_rpc.ts:23` (5 min default).
- Don't force a session restart — pi's error handling is good.
- Simpler than session reset, and matches existing RPC timeout semantics.

---

## TDD Order

### Server-side: emit `srv.request` when pi asks

#### Test: `server/test/adapters/pi.test.ts` — `askUser callback routes to srv.request`

**Red:** Pi adapter's `askUser` callback receives a UI request → test verifies a `srv.request` frame was sent to the reverse RPC.

```typescript
test("pi adapter's askUser callback sends srv.request", async () => {
  const sent: OutgoingFrame[] = [];
  const rpc = new ReverseRpc({ send: (f) => sent.push(f) });

  const adapter = new PiAdapter();

  // Inject askUser callback that feeds to rpc
  await adapter.start({
    cwd: "/tmp",
    sessionId: "sess-1",
    askUser: (req) => rpc.askDevice(req, "sess-1"),
  });

  // Fake pi emitting a ui.select
  adapter.emit("event", {
    kind: "agent.message",
    payload: { text: "... choices: [a, b]" },
  });
  // TODO: simulate the actual pi ui.select RPC that triggers askUser

  const req = sent.find((f) => f.t === "srv.request");
  assert.ok(req);
  assert.deepEqual(req.body.questions[0].options, ["a", "b"]);
});
```

**Green:** Wire `this.askUser` call in `pi.ts:handleUiCall` → it calls `opts.askUser()` which is bound to `rpc.askDevice()`.

```typescript
// In pi.ts:handleUiCall, for case "select":
const resp = await this.askUser?.({
  kind: "askUserQuestion",
  sessionId: this.sessionId,
  questions: [{ header: "Select", question: "...", options: [...] }],
});
```

---

### App-side: render approval UI and send `srv.response`

#### Test 1: `app/test/approval_dialog_test.dart` — `renders approval UI on srv.request frame`

**Red:** StoreController receives a `srv.request` frame → test verifies an ApprovalDialog is rendered with correct buttons.

```dart
test("ApprovalDialog renders on srv.request frame", () {
  final tester = WidgetTester();

  // Inject a fake StoreController
  final controller = FakeStoreController()
    ..incomingFrames.add(Envelope(
      v: 1,
      t: MsgType.srvRequest,
      id: "req-1",
      body: {
        "questions": [{
          "header": "Approve tool call?",
          "options": ["Approve", "Deny"],
        }],
      },
    ));

  await tester.pumpWidget(MaterialApp(
    home: ApprovalDialog(),
  ));

  expect(find.text("Approve tool call?"), findsOneWidget);
  expect(find.byType(ElevatedButton), findsWidgets(count: 2));
});
```

**Green:** Add `ApprovalDialog` to `app/lib/ui/approval/approval_dialog.dart`:
- Listen to `storeProvider` for incoming frames
- Filter for `MsgType.srvRequest`
- Extract questions + options
- Render modal with buttons

#### Test 2: `app/test/approval_dialog_test.dart` — `button tap sends srv.response`

**Red:** User taps "Approve" → test verifies `srv.response` was sent to the outgoing stream.

```dart
test("ApprovalDialog sends srv.response on button tap", () async {
  final outgoing = <Envelope>[];
  final controller = FakeStoreController()
    ..onSend = (env) => outgoing.add(env);

  await tester.pumpWidget(/* as above */);
  await tester.tap(find.text("Approve"));
  await tester.pumpAndSettle();

  final resp = outgoing.whereType<Envelope>().firstWhere(
    (e) => e.t == MsgType.srvResponse && e.id == "req-1"
  );
  expect(resp.body["answer"], "Approve");
});
```

**Green:** `ApprovalDialog` button tap → `storeProvider.notifier.sendResponse(requestId, answer)` → ConnectionController sends `srv.response` frame.

---

### E2E: stub server → app → agent continues

#### Test: `app/test/e2e/approval_e2e_test.dart` — `session awaiting approval flows end-to-end`

**Red:**
1. Stub server emits `session.status { status: "awaiting-approval" }`
2. App renders approval UI
3. User taps "Approve"
4. Stub server receives `srv.response` with matching request ID

```dart
test("e2e: awaiting-approval → approval UI → srv.response → session continues", () async {
  // 1. Spin up stub server + app
  final stubServer = StubServer();
  await app.connect(stubServer.url);

  // 2. Stub: emit session.status awaiting-approval + srv.request
  stubServer.emitEvent(SessionEvent(
    kind: "session.status",
    payload: { "status": "awaiting-approval" },
  ));
  stubServer.emitFrame(Envelope(
    t: MsgType.srvRequest,
    id: "req-123",
    body: { "questions": [{ "options": ["Yes", "No"] }] },
  ));

  // 3. App renders approval UI
  await tester.pumpAndSettle();
  expect(find.text("Approve?"), findsOneWidget);

  // 4. User taps
  await tester.tap(find.text("Yes"));
  await tester.pumpAndSettle();

  // 5. Verify stub server saw srv.response
  final resp = stubServer.capturedFrames.whereType<Envelope>()
    .firstWhere((e) => e.t == MsgType.srvResponse && e.id == "req-123");
  expect(resp.body["answer"], "Yes");
});
```

**Green:** Wire end-to-end:
- Stub server pushes `srv.request` frame
- App's `StoreController` receives frame, routes to `ApprovalDialog`
- Dialog renders, user taps
- Dialog calls `storeProvider.notifier.sendResponse()`
- ConnectionController sends `srv.response` frame back to stub

---

## Seams & SOLID

### 1. AskUser callback injection (Single Responsibility)

**Concern:** Pi adapter shouldn't know about `ReverseRpc` internals.

**Proposal:** Keep AskUser as a simple callback interface. The session manager wires `ReverseRpc.askDevice` into `Session.spawn(askUser)`. Pi adapter just calls the callback.

```typescript
// session.ts
const rpc = new ReverseRpc(ws);
const askUser = (req: AskUser) => rpc.askDevice(req, sessionId);
const adapter = new PiAdapter();
await adapter.start({ ..., askUser });
```

### 2. Frame routing (Open/Closed Principle)

**Concern:** App's `StoreController` needs to route `srv.request` → `ApprovalDialog` without hardcoding.

**Proposal:** Emit a dedicated provider for pending approvals:

```dart
final pendingApprovalProvider = StateProvider<Envelope?>(null);

// StoreController._onFrame
if (env.t == MsgType.srvRequest) {
  ref.read(pendingApprovalProvider.notifier).state = env;
}

// ApprovalDialog observes pendingApprovalProvider
```

This way, new UI can observe approvals without modifying StoreController.

### 3. Idempotent responses (Testability)

**Concern:** Network glitch causes duplicate `srv.response` frames. Should not double-approve.

**Proposal:** Server-side idempotency:

```typescript
// reverse_rpc.ts
if (this.pending.has(id)) {
  const { resolve } = this.pending.get(id)!;
  this.pending.delete(id); // Consume once
  resolve(response);
} else {
  // Duplicate response, already resolved. Silently drop.
}
```

Test: send two `srv.response` with same ID, verify only one resolves.

---

## Implementation Sequence (blocking order)

1. **Server test** (`pi.test.ts`): askUser → srv.request ✅
2. **Server impl** (pi.ts): wire askUser callback to ReverseRpc ✅
3. **App test** (approval_dialog_test.dart): frame → UI ✅
4. **App impl** (approval_dialog.dart): render + send response ✅
5. **E2E test** (approval_e2e_test.dart): stub server + app flow ✅

**Estimated effort:** ~12 hours (server 2h, app UI 3h, app transport 2h, E2E 3h, debug/docs 2h).

---

## Open questions (resolved post-MVP)

- [ ] How to handle concurrent approvals (queue or parallel)? → Start: serialize
- [ ] Notification persistence across app restart? → Start: ephemeral
- [ ] Lock-screen actions? → Phase 2 (SPEC-07, not Slice 1)
