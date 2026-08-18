# SPEC-background-wake-notifications — Slice 2: Background wake for notifications (content-free push over a private tailnet)

**Status:** implemented · ready for on-device validation
**Depends on:** [SPEC-actionable-notifications](./20260708-000800-SPEC-actionable-notifications.md) (Slice 1 actionable notifications)
**Touches (new):** `server/src/push/{sender,payload,wake_coordinator,config,apns}.ts`,
`server/test/push_payload.test.ts`, `server/test/wake_coordinator.test.ts`,
`server/test/push_register.test.ts`, `server/test/reverse_rpc_wake.test.ts`,
`app/lib/notifications/pending_action_drain.dart`,
`app/lib/notifications/push_registration.dart`,
`app/test/pending_action_drain_test.dart`, `app/test/push_registration_test.dart`
**Touches (edit):** `server/src/ws/reverse_rpc.ts`, `server/src/server.ts`,
`server/src/pairing/registry.ts`, `server/src/index.ts`, `server/src/protocol.ts`,
`app/lib/store/connection.dart`, `app/lib/main.dart`, `app/lib/transport/protocol.dart`,
`app/ios/Runner/Info.plist`, `app/ios/Runner/Runner.entitlements`

## Goal / Why

Make the "your agent needs you" loop fire **reliably when the app is force-quit
or long-suspended and the phone is locked**. Slice 1 (SPEC-actionable-notifications) delivers
actionable notifications only while the app process is alive with a live/recently
-suspended WebSocket. iOS aggressively kills suspended apps and their sockets, so
"away for 20+ minutes" needs an OS-level **wake signal**.

The tension: makit is private-by-default — the phone reaches the desktop only over
a Tailscale tailnet, **no cloud backend**. But OS push (APNs) *is* a cloud path
Apple controls, and there is no way to reach a tailnet-only server from Apple's
edge. Resolution: **push is a content-free wake signal only**. The push body
carries **no session data** — at most a generic "you have N pending item(s)".
On wake, the app reconnects over the private tailnet and pulls the real
approval/question via the existing `srv.request` WSS path. The cloud sees a
bearer-less ping; all real data stays on the tailnet.

## Design decisions

### 1. Push transport / relay model — **server sends to APNs directly (no third-party relay)**

makit's server runs on the user's Mac, which has internet and can hold an APNs
auth key. The server signs an ES256 JWT from the user's own `.p8` key and POSTs
to `api.push.apple.com` (HTTP/2) itself. **No shared hosted relay.** This matches
the private/no-cloud ethos: the only cloud hop is Apple's mandatory APNs edge,
and makit operates no intermediary that could see tokens or metadata.

- **Rejected: shared hosted relay.** Lower setup friction, but it re-introduces a
  makit-operated cloud service that sees every device token and wake event — the
  exact thing the product promises not to do. Not worth the operational + trust cost.
- **Android/FCM: deferred behind the same seam.** FCM requires a Google project +
  service account and the same content-free approach. Implement the `PushSender`
  interface now with an iOS/APNs adapter; add `FcmPushSender` in a follow-up. The
  per-device `pushPlatform` field (`"apns"|"fcm"`) is the routing seam; the
  registry, wake coordinator, payload builder, and app drain are all platform-agnostic.

### 2. Testability boundary — **`PushSender` is a pluggable interface; real APNs is behind config**

Real APNs delivery, native push-capability, and APNs-token retrieval cannot be
unit-tested in this repo. So:

- **`PushSender` interface** (`server/src/push/sender.ts`) with `NoopPushSender`
  (default in dev/test/when unconfigured) and `ApnsPushSender` (real, HTTP/2,
  behind `~/.makit/push.json`). The real adapter is **not** unit-tested.
- On the app, an analogous `PushRegistrar` interface (`NoopPushRegistrar` default;
  a real APNs/FCM token provider behind a platform channel/plugin) isolates native
  token retrieval.
- **Unit-tested (pure/deterministic):** (a) the content-free **payload** builder,
  (b) the **wake decision** (which devices to wake), (c) **token registration +
  persistence** in the registry + the `push.register` cmd handler, (d) the
  ReverseRpc **keep-pending-on-no-socket + replay** logic, (e) the app-side
  **pending-action drain** planning and the `push.register` body builder.
- **Not unit-tested (platform I/O):** `ApnsPushSender` HTTP/2 send, native token
  retrieval, iOS background-launch behavior, entitlements — covered by the on-device
  checklist.

### 3. Two halves — both in scope

**(A) Server → device wake.** The device registers its push token via a new
`push.register` `cmd`; the server persists it per-device in
`~/.makit/devices.json`. The single choke point for approvals/questions is
`ReverseRpc.askDevice` (both the connector bridge in `index.ts` and `host.ask`
in `server.ts` funnel through it). When `askDevice` finds **`sent === 0`** (no
live subscribed socket for the target), it invokes an injected
`onUndeliverable(envelope, { sessionId?, pendingCount }) => boolean` hook. The
`WakeCoordinator` behind that hook wakes every paired device that has a token and
**no live socket** (`connectedDeviceIds()` from `server.ts`).

**Keep-pending is gated on a *real* dispatch — never on token presence.** The
hook returns `true` **only when the `PushSender` actually dispatched a wake**:
`sender.enabled === true` **and** at least one `devicesToWake` target existed.
`askDevice` keeps the request pending (up to `timeoutMs`) **iff** the hook
returned `true`. Concretely:
- `NoopPushSender.enabled === false` → `WakeCoordinator.wake` returns `false`
  even when a (stale) token is stored → `askDevice` **rejects immediately**,
  exactly matching Slice-1 today. A dead token can never make the connector hang
  for the full 5-min timeout with nothing to wake.
- A real, enabled sender **with** ≥1 not-connected token-bearing device →
  `wake` returns `true` → the request **stays pending** so the woken device can
  answer.

> **Keep-pending contract:** *reject immediately unless a real wake was
> dispatched.* Token presence alone is never sufficient.

**(B) Device wake + replay.** On wake the app reconnects (existing
`ConnectionController._boot`/`onAppResumed` path), authenticates, and the server
**replays pending `srv.request`s** to the freshly-authed client (see decision 3
note below). `SrvRequestHandler` sees them on the `srvRequests` stream and — being
backgrounded — presents the Slice-1 actionable notification. **Additionally**, on
next launch/reconnect the app **drains the `makit_pending_actions` SharedPreferences
queue** (force-quit taps captured by Slice 1's `notificationBackgroundHandler`
isolate) through `responseForAction` → `respondTo`, idempotently and in FIFO order.

> **Replay scope note.** A force-quit-then-woken app has an **empty** `_subscribed`
> set (store.dart), so replay-on-`sub` is insufficient. The server therefore
> replays **all** pending `srv.request`s to a client **on auth**, regardless of
> subscription. The replay call lives **only** in the `onAuthenticated` wrapper
> passed to `AuthGate` (a new `function onAuthenticated(client) { sendSnapshots(client);
> rpc.replayPendingTo(client); }` in `server.ts`) **and** in `hub.handleSub`. It
> must **not** live in `sendSnapshots` itself, because `broadcastSnapshots` calls
> `sendSnapshots` on every session event and would re-fire replay constantly.
> Safe because makit is single-user and every paired device belongs to the user;
> the wake means "come get your pending items." Delivery is de-duplicated per
> client (a pending request is sent to a given client at most once).

### 4. Privacy assertion — **the wake payload schema is provably content-free**

The genuine, structural guarantee is in the **signature**:
`buildWakePayload({ pendingCount: number }): ApnsPayload`
(`server/src/push/payload.ts`) accepts **only an integer** — no `Envelope`, no
session id, no request body, no message text is ever in scope, so no session data
*can* leak into the payload by construction. This is stronger than a fixed-string
body assertion (which only checks the value it happens to build today).

A unit test (`server/test/push_payload.test.ts`) backs this up by **recursively**
walking the payload: it allowlists the key set at **every** level of the
dictionary — top-level (`{aps}`), `aps` (`{alert, sound, badge, "content-available"}`),
and nested `aps.alert` (`{title, body}`) — so if a future change adds a
dynamic-text field such as `aps.alert.subtitle`, the recursive allowlist assertion
fails. It also collects every string value recursively and asserts none contains
any session/request/message probe substring. See TDD step A1.

### 5. Graceful degradation — **no hard dependency on push**

- If `~/.makit/push.json` is absent/invalid → server uses `NoopPushSender`; wakes
  are no-ops; behavior falls back to Slice-1 (works only while app alive). The
  server logs a one-line hint at startup.
- If the user declines the iOS push permission or no token is retrieved → the app
  never sends `push.register`; the server has no token to wake → same Slice-1
  fallback. The pairing/settings screen explains the tradeoff.
- `askDevice` still **rejects immediately** with "no subscribed clients to ask"
  whenever no *real* wake is dispatched — i.e. the `onUndeliverable` hook returned
  falsy. This covers: no `NoopPushSender` config (`sender.enabled === false`, even
  with a stale stored token), all devices already connected, or no token at all.
  A stored token is **never** sufficient on its own to keep the request pending,
  preserving today's connector semantics.

## Data flow

```
Desktop agent raises approval/question
  → bridge.askDevice (index.ts)  ─┐         host.ask (server.ts) ─┐
                                   └──────────┬────────────────────┘
                                              ▼
                        ReverseRpc.askDevice(body, {sessionId})
                              │  sends srv.request to every AUTHED + subscribed client
                              │  count = sent
                              ├─ sent > 0 ────────────────► live device (Slice-1 path)
                              └─ sent === 0
                                   │ keep := onUndeliverable(envelope,
                                   │            { sessionId, pendingCount: rpc.pendingCount })
                                   │   ← pendingCount comes from ReverseRpc.pendingCount getter
                                   │   keep === true  → leave pending entry+timer (await response)
                                   │   keep === false → reject "no subscribed clients to ask"
                                   ▼
                     WakeCoordinator.wake(envelope, {sessionId, pendingCount}): boolean
                        │ if (!sender.enabled) return false            ← Noop → reject now
                        │ targets = devicesToWake({pairedDevices: registry.list(),
                        │                          connectedDeviceIds})
                        │   = paired ∧ hasToken ∧ ¬connected
                        │ if (targets.length === 0) return false       ← nothing to wake → reject
                        │ payload = buildWakePayload({pendingCount})   ← CONTENT-FREE (int only)
                        │ fire-and-forget: for t of targets → sender.wake(t, payload)
                        │   (async; on 'dead' 410/BadDeviceToken → registry.clearPushToken(t.deviceId))
                        │ return true                                  ← real wake dispatched → stay pending
                        ▼
                     PushSender.wake(target, payload)   (NoopPushSender.enabled=false | ApnsPushSender.enabled=true)
                        ▼
                     APNs edge (Apple)  ──push──►  iPhone (locked, app killed)
                        ▼
   [content-free alert buzzes user]  +  [content-available wakes app in background]
                        ▼
        App launches/resumes → ConnectionController._boot → WSS over Tailscale
                        ▼
        hello(bearer) → AuthGate → onAuthenticated(client)   [server.ts wrapper]
                        │  sendSnapshots(client)
                        ▼
        ReverseRpc.replayPendingTo(client)  ── re-sends pending srv.request(s), once/client
                        ▼
        ConnectionController.srvRequests → SrvRequestHandler._dispatch
                        │  _foreground == false  → NotificationService.show(category, payload)
                        ▼
        user taps Approve/Deny/Reply  → onAction → responseForAction → respondTo(rid, body)
                        ▼
        srv.response {id: rid} → ReverseRpc.handleResponse → resolves the pending askDevice

Parallel (force-quit taps captured by Slice-1's background isolate):
  notificationBackgroundHandler → SharedPreferences[makit_pending_actions]
      ⋯ (app killed) ⋯
  next launch/reconnect (wsState → connected)
      → PendingActionDrainer.drain()
          → planDrain(queue) → [(rid, body)]  (FIFO)
          → respondTo(rid, body)  [idempotent]
          → clear makit_pending_actions
```

## TDD steps (ordered; each independently verifiable)

Server tests run under the existing `server/` test runner (`node --test` /
whatever `server/test/*.test.ts` uses); app tests under `flutter test`.

### Half A — server → device wake

**A1. Content-free wake payload (+ privacy assertion).**
*Files:* NEW `server/src/push/payload.ts`, `server/test/push_payload.test.ts`.
*Unit:* `buildWakePayload({ pendingCount }: { pendingCount: number }): ApnsPayload`.
The **signature is the privacy invariant**: it takes only an integer, so no
session/request data is ever in scope to leak. `pendingCount` is produced by
`ReverseRpc.pendingCount` (see A5) and threaded through `onUndeliverable`.
*Failing test first:*
- `"wake payload key set is allowlisted recursively"` — assert the key set at
  **every** dictionary level: top-level `Object.keys(p)` == `{aps}`;
  `Object.keys(p.aps)` ⊆ `{alert, sound, badge, "content-available"}`;
  `Object.keys(p.aps.alert)` ⊆ `{title, body}`. Walk nested objects generically so
  a future dynamic-text field (e.g. `aps.alert.subtitle`) is rejected.
- `"wake payload contains no session content"` — build with a probe set
  `['sess-123','srv-999','rm -rf /','confirmAction','What branch?']`; recursively
  collect every string in the payload; assert none contains any probe substring.
- `"alert body is a fixed generic string"` — assert `p.aps.alert.body` equals the
  constant generic string regardless of input; `"badge reflects pendingCount"` —
  assert `buildWakePayload({pendingCount: 3}).aps.badge === 3`.
*Production:* pure builder returning
`{ aps: { alert: { title: "makit", body: "An agent needs you" }, sound: "default", badge: pendingCount, "content-available": 1 } }`.

**A2. Wake decision + dispatch gate.**
*Files:* NEW `server/src/push/wake_coordinator.ts`, `server/src/push/sender.ts`,
`server/test/wake_coordinator.test.ts`.
*Unit (pure):* `devicesToWake({ pairedDevices, connectedDeviceIds }): PushTarget[]`.
*Unit (gate):* `WakeCoordinator({ registry, connectedDeviceIds, sender, buildWakePayload })`
with `wake(envelope, { sessionId?, pendingCount }): boolean`. `PushSender` gains a
`readonly enabled: boolean` and `wake(target, payload): Promise<'ok'|'dead'|'error'>`;
`NoopPushSender.enabled === false`.
*Failing test first (decision):* `"wakes only paired devices with a token and no
live socket"` — devices `[connected+token, notConnected+token, notConnected+noToken]`,
`connectedDeviceIds={d1}` → result == `[{deviceId:d2, token, platform}]`; and
`"returns empty when every paired device is connected"`.
*Failing test first (gate — the keep-pending contract):*
- `"wake returns false with NoopPushSender even when a stale token is stored"` —
  `sender.enabled=false`, one not-connected token-bearing device → `wake(...)`
  returns `false` and `sender.wake` is never called (reject-immediately path).
- `"wake returns true when an enabled sender has ≥1 target"` — fake enabled sender,
  one not-connected token-bearing device → returns `true`, `sender.wake` called once
  with `buildWakePayload({pendingCount})`.
- `"wake returns false when enabled but no device needs waking"` — all connected →
  `false`, `sender.wake` not called.
- `"wake clears a dead token on 410/BadDeviceToken"` — fake sender resolves `'dead'`
  for d2 → assert `registry.clearPushToken('d2')` invoked (async, best-effort).
*Production:* `wake` returns `false` immediately if `!sender.enabled` or
`devicesToWake(...)` is empty; otherwise fire-and-forget `sender.wake` for each
target (mapping `'dead'` → `registry.clearPushToken(deviceId)`) and return `true`.
The boolean is the synchronous keep-pending gate; APNs accept/reject is async and
never blocks it.

**A3. Token persistence in the registry.**
*Files:* EDIT `server/src/pairing/registry.ts`, NEW `server/test/push_register.test.ts` (registry half).
*Unit:* `DeviceRegistry.setPushToken(deviceId, {token, platform, env})`,
`clearPushToken(deviceId)`; `PairedDevice` gains optional `pushToken/pushPlatform/pushEnv`.
*Failing test first:*
- `"setPushToken persists across reload"` — set token, construct a new
  `DeviceRegistry` (reads `MAKIT_HOME/devices.json`), assert `list()[0].pushToken`.
- `"clearPushToken drops the token and persists across reload"` — set then
  `clearPushToken(id)`; new `DeviceRegistry` → `list()[0].pushToken` is `undefined`
  while the device itself remains paired. (This is the stale-token lifecycle
  target invoked by A2's dead-token path and by A7's 410 disposition.)
- `"revoke clears the push token"` — revoke drops the device (and thus its token).
- `"setPushToken/clearPushToken on unknown device is a no-op"`.
*Production:* mutate the device, `persist()` (0600 preserved). Use a temp
`MAKIT_HOME` in the test.

**A4. `push.register` cmd handler.**
*Files:* EDIT `server/src/server.ts` (register cmd), `server/src/protocol.ts`
(document the kind), NEW `server/test/push_register.test.ts` (handler half, via a
`CommandRouter` + fake `WsClient` + fake registry).
*Unit:* handler for `cmd {kind:'push.register', token, platform, env?}`.
*Failing test first:*
- `"push.register stores the token for the authed device"` — dispatch on a client
  with `deviceId='d1'`; assert `registry.setPushToken('d1', {token, platform})` and
  an `ack`.
- `"push.register with no token → err bad_request"`.
- `"push.register from an unauthed/deviceless client → err"`.
*Production:* `r.register("push.register", …)` reading `ctx.env.token/platform`,
calling `registry.setPushToken(ctx.client.deviceId, …)`, `ctx.ack()`.

**A5. ReverseRpc: wake + keep-pending gated on a real dispatch.**
*Files:* EDIT `server/src/ws/reverse_rpc.ts`, NEW `server/test/reverse_rpc_wake.test.ts`.
*Unit:* `ReverseRpc` gains an `onUndeliverable?(env, { sessionId?, pendingCount }) => boolean`
dep, a `get pendingCount(): number` getter (returns `this.pending.size`), and
stores the sent `envelope` in each `PendingRequest`. When `sent === 0` it calls
`this.deps.onUndeliverable?.(envelope, { sessionId, pendingCount: this.pendingCount })`
and keeps the entry pending **iff** the hook returned a truthy value; otherwise it
rejects with "no subscribed clients to ask" (today's behavior).
*Failing test first (ReverseRpc unit, hook injected directly):*
- `"keeps request pending when onUndeliverable returns true"` — no clients; hook
  returns `true` → promise is **not** rejected synchronously; hook was called with
  the envelope and a numeric `pendingCount`; a later `handleResponse({id, …})`
  resolves it.
- `"rejects immediately when onUndeliverable returns false"` — hook returns
  `false` → promise rejects with "no subscribed clients to ask".
- `"pendingCount getter reflects in-flight requests"` — seed N pending; assert the
  value the hook observed equals N.
*Failing test first (end-to-end gate, wiring a real `WakeCoordinator` as the hook):*
- `"Noop sender + stale stored token → askDevice rejects immediately (no hang)"` —
  `onUndeliverable = coord.wake` with `NoopPushSender` and a registry holding a
  not-connected token-bearing device → the promise rejects synchronously; no timer
  is left armed.
- `"real (enabled fake) sender + token + not-connected → stays pending"` — same
  registry with an enabled fake sender → promise stays pending and resolves on a
  later `handleResponse`.
*Production:* on `sent === 0`, invoke the hook and branch on its boolean; leave the
pending entry + timer in place only when it is truthy.

**A6. ReverseRpc: replay pending to a newly-authed client (once).**
*Files:* EDIT `server/src/ws/reverse_rpc.ts`, same test file A5.
*Unit:* `replayPendingTo(client: WsClient): number` — re-sends every pending
envelope the client has not yet been sent; tracks per-pending `deliveredTo` so the
same request is never delivered twice to the same client.
*Failing test first:* `"replayPendingTo delivers each pending request once per client"`
— seed one pending request; `replayPendingTo(fakeClient)` sends exactly one
`srv.request`; a second `replayPendingTo(fakeClient)` sends nothing.
*Production wiring (not unit-tested):* in `server.ts`, call `rpc.replayPendingTo(client)`
**only** from the `onAuthenticated` wrapper (a new
`function onAuthenticated(client) { sendSnapshots(client); rpc.replayPendingTo(client); }`
passed to `new AuthGate({ registry, onAuthenticated, hostToken })`) and from
`hub.handleSub`. Do **not** call it from `sendSnapshots`: `broadcastSnapshots`
invokes `sendSnapshots` on every session event, so replay there would re-fire
constantly. `deliveredTo` still guards against double-delivery, but the correct
placement keeps replay tied to auth/subscription events only.

**A7. APNs stale-token disposition (410 / BadDeviceToken).**
*Files:* NEW `server/src/push/apns.ts` (pure disposition helper), extend
`server/test/wake_coordinator.test.ts` (or NEW `server/test/apns_disposition.test.ts`).
*Unit (pure):* `apnsDisposition(status: number, reason?: string): 'ok'|'dead'|'error'`
— maps APNs feedback to the `PushSender.wake` result. The HTTP/2 send itself (W2)
is platform I/O and stays un-unit-tested; this classifier is pure and testable.
*Failing test first:*
- `"410 Unregistered → dead"` — `apnsDisposition(410, 'Unregistered') === 'dead'`.
- `"400 BadDeviceToken → dead"` — `apnsDisposition(400, 'BadDeviceToken') === 'dead'`.
- `"200 → ok"`; `"429/500/503 → error"` (transient, token kept).
*Production:* `ApnsPushSender.wake` returns `apnsDisposition(res.status, reasonBody.reason)`;
`WakeCoordinator` (A2) maps `'dead'` → `registry.clearPushToken(target.deviceId)`
so a dead token stops triggering wake-then-hang on the next `askDevice`.

### Half B — device wake + replay

**B1. Pending-action drain planning.**
*Files:* NEW `app/lib/notifications/pending_action_drain.dart`,
`app/test/pending_action_drain_test.dart`.
*Unit:* pure `List<PendingReplay> planDrain(List<String> rawQueue)` where each
`rawQueue` entry is the `{payload, actionId, input}` JSON written by
`notificationBackgroundHandler`. Reuses `parseNotificationPayload` +
`responseForAction`.
*Failing test first:*
- `"planDrain maps queued approve/deny/reply taps to responses in FIFO order"` —
  queue of `[approve(r1), reply(r2, 'yes')]` → `[(r1,{kind:'confirmAction',approved:true}), (r2,{kind:'askUserQuestion',answers:['yes'],…})]`.
- `"planDrain skips entries with unknown action, missing rid, or garbage JSON"`.
*Production:* decode each entry, `parseNotificationPayload(payload)` → rid+kind,
`responseForAction(kind, actionId, input)` → body; skip nulls; preserve order.

**B2. Drainer replays then clears the queue (idempotent).**
*Files:* same as B1.
*Unit:* `PendingActionDrainer(prefs, respond)` where `respond(rid, body)` is
injected (the `respondTo` tear-off). `drain()` reads `kPendingActionsKey`, calls
`planDrain`, invokes `respond` for each, then clears the key.
*Failing test first:* `"drainer replays each queued action then clears the key"` —
seed `SharedPreferences` (via `SharedPreferences.setMockInitialValues`) with two
entries; run `drain()`; assert `respond` called twice with the mapped bodies and
`prefs.getStringList(kPendingActionsKey)` is empty afterward. Idempotency is
guaranteed downstream by `respondTo`'s existing `_respondedRequests` guard
(SPEC-actionable-notifications step 4) — note in the test that a re-run is a no-op because the queue was
cleared.

**B3. `push.register` body builder.**
*Files:* NEW `app/lib/notifications/push_registration.dart`,
`app/test/push_registration_test.dart`; EDIT `app/lib/transport/protocol.dart`
(add `CmdKind.registerPush → 'push.register'`).
*Unit:* pure `Map<String,dynamic> pushRegisterBody({required String token, required String platform})`.
*Failing test first:* `"pushRegisterBody builds the register cmd body"` →
`{'kind':'push.register','token':token,'platform':platform}`.
*Production:* the builder + a `PushRegistrar` interface (`NoopPushRegistrar`
default) with a real APNs/FCM token provider behind a platform channel.

### Production wiring (not unit-tested; verified on-device)

**W1. Server config + sender selection + wiring topology.** NEW
`server/src/push/config.ts` loads `~/.makit/push.json`. `server/src/index.ts` builds
the sender only — `NoopPushSender` when config is absent/invalid, else
`ApnsPushSender` — and passes it into `startWsServer` via `ServerOpts` alongside
the already-present `registry`, plus `buildWakePayload`. **The `WakeCoordinator`
is constructed inside `server.ts`, not `index.ts`**, because `connectedDeviceIds`
is a closure defined in `server.ts` and only exists on the returned object —
`index.ts` cannot build the coordinator or inject `onUndeliverable` before
`ReverseRpc` is created. So:
- `ServerOpts` gains `sender: PushSender` and `buildWakePayload: typeof buildWakePayload`
  (`registry` is already there).
- In `server.ts`, after `connectedDeviceIds` is defined, construct
  `const wakeCoordinator = new WakeCoordinator({ registry, connectedDeviceIds, sender, buildWakePayload })`
  and create `ReverseRpc` with `onUndeliverable: (env, ctx) => wakeCoordinator.wake(env, ctx)`.
- `index.ts` no longer references `ReverseRpc`/`WakeCoordinator`/`connectedDeviceIds`;
  it only chooses the sender and forwards it in `ServerOpts`.

**W2. Real APNs adapter.** NEW `server/src/push/apns.ts` — ES256-signs a JWT from
the `.p8`, HTTP/2 POST to `api.push.apple.com` (or `api.sandbox.push.apple.com`
for `env:"sandbox"`), `apns-topic: <bundleId>`, `apns-push-type: alert`,
`apns-priority: 10`. `ApnsPushSender.enabled === true`. `wake()` returns
`apnsDisposition(status, reason)` (pure, unit-tested in A7); the coordinator maps
`'dead'` → `registry.clearPushToken`. Best-effort; a failed/`'error'` send logs and
never throws into `askDevice`.

**W3. App: register token + drain on connect.** EDIT `app/lib/store/connection.dart`
to send the `push.register` cmd after a successful (re)connect when a token is
available; EDIT `app/lib/main.dart` to construct `PendingActionDrainer` and run
`drain()` on the `wsState → connected` transition (mirrors store.dart's
re-subscribe-on-reconnect listener).

**W4. iOS capabilities.** `Runner.entitlements`: `aps-environment` =
`development`/`production`. `Info.plist`: `UIBackgroundModes` += `remote-notification`.
`AppDelegate` registers for remote notifications and forwards the APNs token to the
Dart `PushRegistrar` channel.

## New files vs edited files

**Server — new:** `push/sender.ts`, `push/payload.ts`, `push/wake_coordinator.ts`,
`push/config.ts`, `push/apns.ts`; tests `push_payload.test.ts`,
`wake_coordinator.test.ts`, `push_register.test.ts`, `reverse_rpc_wake.test.ts`
(plus the A7 `apnsDisposition` assertions, in `wake_coordinator.test.ts` or a new
`apns_disposition.test.ts`).
**Server — edit:** `ws/reverse_rpc.ts` (onUndeliverable dep with `{sessionId,
pendingCount}`, `pendingCount` getter, store envelope, `replayPendingTo`), `server.ts`
(push.register cmd, `ServerOpts.sender`+`buildWakePayload`, construct `WakeCoordinator`
and wire `onUndeliverable` here, `onAuthenticated` wrapper for replay), `pairing/registry.ts`
(push token fields + setter/clear), `index.ts` (load config, build sender, pass in
`ServerOpts` — no coordinator/ReverseRpc references), `protocol.ts` (document push.register).

**App — new:** `notifications/pending_action_drain.dart`,
`notifications/push_registration.dart`; tests `pending_action_drain_test.dart`,
`push_registration_test.dart`.
**App — edit:** `store/connection.dart` (send push.register on connect),
`main.dart` (wire drainer on connected), `transport/protocol.dart`
(`CmdKind.registerPush`), `ios/Runner/Info.plist`, `ios/Runner/Runner.entitlements`,
`ios/Runner/AppDelegate.swift`.

## Test plan

**Unit-tested (CI):**
- Server: A1 payload + recursive privacy assertion, A2 wake decision + dispatch
  gate + dead-token clear, A3 registry persistence + `clearPushToken`, A4
  push.register handler, A5 ReverseRpc keep-pending-iff-real-dispatch +
  `pendingCount`, A6 replay-once, A7 `apnsDisposition` (410/BadDeviceToken).
- App: B1 drain planning, B2 drainer-clears-queue, B3 push.register body.

**Not unit-tested (platform I/O):** `ApnsPushSender` HTTP/2 send, JWT signing,
native APNs token retrieval, iOS background-launch, entitlements/Info.plist,
connection.dart/main.dart wiring.

**On-device checklist (extend `makit-e2e-testing`; requires a real iPhone + APNs key):**
1. Configure `~/.makit/push.json` (sandbox), pair the device, confirm the server
   logs "push: APNs sender active" and the device sent `push.register`
   (`makit devices` shows a token present, value redacted).
2. **Force-quit** the app, **lock** the phone. Trigger `confirmAction` on the
   desktop (`server/connectors/makit-piano.ts piano_confirm`). Within a few seconds
   the phone buzzes with the generic content-free alert.
3. If the app got background time: it upgrades to the actionable Approve/Deny
   notification; tapping **Approve** on the lock screen resolves the approval on
   the desktop without opening the app.
4. If it did not: tapping the generic alert launches the app, which reconnects,
   pulls the pending request, and presents it (dialog or notification).
5. **Force-quit tap capture:** while alive, background the app so an actionable
   notification is shown; force-quit; tap **Approve** from the lock screen; relaunch
   → the queued action drains and the approval resolves exactly once.
6. `askUserQuestion` wake → Reply → `answers[0]` reaches the agent.
7. **Privacy:** capture the APNs payload (Console.app / a proxy) and confirm no
   session/message content is present.
8. **Degradation:** remove `push.json`, repeat step 2 → no wake, Slice-1 behavior
   only; decline push permission → no `push.register`, same fallback.
9. **Revoke:** `makit devices revoke <id>` → no further wakes to that device.

## Config / onboarding

The user brings their own APNs key (private, no makit-operated cloud):

1. **Apple Developer:** create an APNs Auth Key (`.p8`), note its **Key ID** and
   **Team ID**; register the app **Bundle ID** (e.g. `dev.makit.app`) with the Push
   Notifications capability.
2. **Xcode (`app/ios`):** enable **Push Notifications** capability and **Background
   Modes → Remote notifications**; set `aps-environment` in `Runner.entitlements`.
3. **Server:** drop the key at `~/.makit/apns/AuthKey_<KEYID>.p8` and create
   `~/.makit/push.json` (mode 0600):
   ```json
   {
     "apns": {
       "keyPath": "~/.makit/apns/AuthKey_ABC123.p8",
       "keyId": "ABC123",
       "teamId": "TEAM456",
       "bundleId": "dev.makit.app",
       "env": "sandbox"
     }
   }
   ```
   Absent/invalid → `NoopPushSender` (graceful degradation). Push tokens live
   per-device in the existing `~/.makit/devices.json` (`pushToken`, `pushPlatform`,
   `pushEnv`), written 0600 by `DeviceRegistry.persist()`.

## Risks / open decisions (with recommendations)

1. **Silent-push throttling & background-launch reliability.** iOS rate-limits and
   may drop `content-available` pushes, and a killed app may not get background
   time to reconnect over Tailscale. **Recommendation:** send a **single push that
   is both a content-free alert and `content-available: 1`** — the alert
   guarantees the user is buzzed regardless of background execution; the
   content-available lets the app opportunistically upgrade to the actionable
   notification. Tapping the alert always foregrounds → reconnect → pull. (Chosen;
   reflected in `buildWakePayload`.)
2. **Tailnet down at wake time.** If Tailscale is not connected when the app wakes,
   the reconnect+pull fails. **Recommendation:** accept — the generic alert already
   notified the user, who can open the app once connectivity returns; the pending
   `srv.request` is replayed on the next successful auth (within the 5-min
   `askDevice` timeout).
3. **`askDevice` timeout vs. away-time.** Default 5 min; a user away longer causes
   the agent to see a timeout/cancel. **Recommendation:** keep 5 min for Slice 2;
   a longer wake-aware timeout is a follow-up (open).
4. **Multi-device fan-out.** Wake **all** paired devices with a token and no live
   socket; first `srv.response` wins (ReverseRpc semantics). Recommended for a
   single-user product; a "primary device" preference is a follow-up.
5. **Replay-on-auth ignores subscription scope.** Justified for single-user (all
   devices are the user's). If makit ever becomes multi-user, scope replay to
   session ownership. (Documented invariant.)
6. **Android/FCM.** Deferred behind the `PushSender`/`pushPlatform` seam; no design
   debt — the registry, coordinator, payload, and app drain are platform-agnostic.
```
