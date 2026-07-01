# Engineering Principles & Architecture Review

> Status: living document. Codifies the principles we hold ourselves to, an
> honest review of the current app + server, and a **red → green → refactor**
> backlog to close the gaps. Update it as items land.

## 1. Principles we hold

Ordered roughly by how often they should change a decision.

1. **TDD / red-green-refactor.** No production behaviour ships without a test
   that failed first. Bugs start as a failing reproduction. "Make it work" is
   not a success criterion; a passing, named test is.
2. **Contract-first protocol.** The wire is the real API. Its shape is defined
   once and both ends conform. Drift is a bug caught by a test, not a code
   review.
3. **Fail-fast at boundaries, trust within.** Validate + parse untrusted input
   (WS frames, pi stdout, files) at the edge into typed values. Interior code
   never re-checks; it works with already-valid domain types.
4. **SOLID.**
   - *SRP*: a unit has one reason to change. God functions/objects are debt.
   - *OCP*: adding a command/event/adapter shouldn't mean editing a growing
     `switch` in a core file — register into a table.
   - *LSP/ISP*: small role interfaces (`AgentAdapter`, `AskUser`) — keep them.
   - *DIP*: depend on abstractions; inject them (see DI).
5. **DI via seams.** Every side effect (transport, clock, storage, subprocess,
   randomness) is injectable so units are testable without the world. Globals
   are acceptable only as a thin composition root.
6. **YAGNI.** No half-built features carried as dead code. Either finish it with
   tests or delete it. Speculative deps are removed.
7. **Explicit error handling + typed errors.** Errors carry a code, not just a
   string. Nothing is swallowed silently on a path a user waits on.
8. **Observability.** One leveled logger per side; no `console.log`/`debugPrint`
   in shipped hot paths. Logs are structured enough to diagnose without a repro.
9. **Determinism & idempotency.** Reducers are pure functions of (state, event).
   Replays and duplicates are safe by construction and covered by tests.
10. **Security by default.** TLS pinning, bearer tokens, `0600` secrets, no
    secret in logs, constant-time token compare, rate-limited pairing.
11. **Immutability.** State is immutable snapshots (`copyWith`); no in-place
    mutation of shared state.

## 2. Architecture snapshot

**Server** (`server/src`, Node/TS, ESM, `tsx`): `index.ts` (composition root) →
`SessionManager` (projects/sessions) → `Session` (append-only event log +
adapter binding) → `AgentAdapter` (`PiAdapter` real / `StubAdapter` test).
`startWsServer` handles TLS+auth+routing; `bridge.ts` + `askDevice` transport
`ctx.ui.*` to the phone; `DeviceRegistry` owns pairing secrets.

**App** (`app/lib`, Flutter/Riverpod): `WsClient` (reconnecting, cert-pinned
transport) → `ConnectionController` (pairing, mDNS rediscovery, connection
state) → `StoreController` (frame decode + domain reducer, optimistic UI) →
providers → widgets. `protocol.dart` mirrors `protocol.ts` by hand.

The layering is sound for the size. The gaps below are about **testability,
validation, and finishing/removing half-built paths** — not a rewrite.

## 3. Findings (prioritized)

Severity: 🔴 correctness/security · 🟠 maintainability/test-gap · 🟡 polish.

| # | Sev | Area | Finding | Principle |
|---|-----|------|---------|-----------|
| F1 | 🔴 | server `handleCmd` | `approve`/`deny` are **unhandled** — the app's approval UI (`store.approve` → `kind:'approve'`) hits the `default` → `"unknown cmd"`. Approvals are half-built. | YAGNI, error-handling |
| F2 | 🔴 | both, wire | **No input validation.** Server coerces (`String(env.x ?? "")`); app hard-casts (`env.body['projects'] as List`) and throws on malformed frames. A bad/hostile frame is silently coerced or crashes the reducer. | fail-fast, security |
| F3 | 🟠 | `startWsServer` | ~390-line **god function**: TLS, auth, subs, command dispatch, reverse-RPC, snapshots, per-client state all in closures. Hard to unit-test; no seams. | SRP, DI |
| F4 | 🟠 | protocol | `protocol.ts` and `protocol.dart` **hand-mirrored** with a "trust the tests" comment. No contract test asserts they agree. Drift is silent until runtime. | contract-first |
| F5 | 🟠 | `StoreController` | Fat controller mixes JSON decoding, DTO mapping, domain reduction, optimistic UI, seq idempotency. The most bug-prone logic (we fixed dup-bubble bugs here) has **zero unit tests**. | SRP, TDD |
| F6 | 🟠 | tests | No unit tests for `DeviceRegistry` (security-critical tokens), `Session` (seq/status), `SessionManager`, `WsClient` (backoff/pinning), `ConnectionController` (rediscovery). Only happy-path e2e. | TDD |
| F7 | 🟠 | command dispatch | Server `switch(kind)` and app frame `switch(kind)` grow per feature. New command = edit core file. | OCP |
| F8 | 🟠 | DI seams | `ConnectionController` news up `WsClient()` directly; `manager.spawnPiSession` always news a `PiAdapter` then discards it when a factory exists. No transport seam for app unit tests. | DIP, DI |
| F9 | 🟡 | observability | `console.log`/`debugPrint` scattered in hot paths (`pi.ts` `[pi.line]`, `store.dart` `_appendEvent`, `session_screen` build). No levels. | observability |
| F10 | 🟡 | YAGNI | Unused: `EventKind.agentThinking`/`tool.call.delta` partially wired; freezed/json_serializable/build_runner deps unused; `debug.ask*` cmds shipped in prod handler. | YAGNI |
| F11 | 🟡 | security | Pair/bearer compared with `Map.get` (not constant-time); no rate limit on pair attempts; bearer is raw in `devices.json` (acceptable for LAN, note it). | security |
| F12 | 🟡 | error surfacing | App `send()` silently no-ops when `_ws == null` — a tapped action can vanish with no feedback. | error-handling |

## 4. Red → green → refactor backlog

Each item: **RED** (write this failing test first) → **GREEN** (smallest change)
→ **REFACTOR** (clean up under green) → **VERIFY**. Ordered by value/risk.

### B1 — Finish or delete approvals (F1) 🔴
- **RED**: server test — `handleCmd({kind:'approve', sessionId, callId})` emits an
  `approval.decision` event and resolves the pending tool; `deny` likewise.
  App test — tapping Approve on `_ApprovalChip` sends `kind:'approve'`.
- **GREEN**: add `approve`/`deny` cases wired to the adapter's approval hook
  (or, if approvals aren't in scope yet, **delete** `_ApprovalChip`,
  `ApprovalRequestItem`, `store.approve`, and the `approval.*` event kinds).
- **REFACTOR**: whichever path — no dead half-feature remains.
- **VERIFY**: unit + an e2e approval round-trip (stub emits `approval.request`).

### B2 — Validate the wire at both boundaries (F2) 🔴
- **RED**: server — feeding a malformed `cmd` (missing `kind`, wrong types)
  yields a structured `err` with a code and never throws. App — a malformed
  `sessions.snapshot` frame is dropped with a logged warning, not an exception.
- **GREEN**: one decode/validate function per side. Server: reintroduce a schema
  layer (zod was removed *because it was never used* — this is where it earns its
  place) or hand-rolled guards returning `Result`. App: a `WireCodec` that
  returns typed DTOs or `null`, mirroring the existing `SessionEvent.fromJson`
  pattern everywhere (snapshots included).
- **REFACTOR**: interior code (`handleCmd`, `StoreController._onFrame`) receives
  already-typed values; drop all inline `as`/coercion.
- **VERIFY**: fuzz-ish table tests of bad frames; existing e2e still green.

### B3 — Extract a pure protocol codec + shared contract (F4, F5) 🔴/🟠
- **RED**: a **contract test** (runs in CI) that builds one canonical sample of
  every message/event kind and asserts server-encode → app-decode and
  app-encode → server-decode round-trip. Fails when either side drifts.
- **GREEN**: extract encode/decode into `server/src/protocol/codec.ts` and
  `app/lib/transport/codec.dart` with a shared fixture set (JSON files checked
  into both). 
- **REFACTOR**: `StoreController._onFrame` becomes `reduce(state, decoded)` — a
  pure function; DTO mapping moves into the codec.
- **VERIFY**: contract test + a new `store_reducer_test.dart`.

### B4 — Unit-test the reducer & idempotency (F5) 🟠
- **RED**: `store_reducer_test.dart` — (a) optimistic user bubble + server echo
  at same seq renders **one** message; (b) out-of-order/duplicate seq dropped;
  (c) `session.commands` advances the cursor without adding a chat item;
  (d) status/preview bubble-up. These encode the bugs we already fixed.
- **GREEN**: they should pass against the extracted pure reducer (B3).
- **REFACTOR**: delete the `debugPrint`s from the reducer once covered.
- **VERIFY**: `flutter test`.

### B5 — Decompose `startWsServer` (F3, F7) 🟠
- **RED**: unit tests for the pieces once they're injectable: `AuthGate`
  (hello → authed / closed), `CommandRouter` (table of `kind → handler`),
  `SubscriptionHub` (sub/unsub/fan-out), `ReverseRpc` (askDevice + timeout).
- **GREEN**: extract those four collaborators; `startWsServer` becomes wiring.
- **REFACTOR**: `CommandRouter` is a registry (OCP) — `router.register(kind, fn)`;
  adding a command no longer edits a switch.
- **VERIFY**: unit tests per collaborator + e2e unchanged.

### B6 — Security-critical unit tests + hardening (F6, F11) 🟠
- **RED**: `DeviceRegistry` tests — pair token is single-use, expires, unknown
  bearer rejected, revoke works, corrupt `devices.json` starts fresh. Then a
  test asserting constant-time bearer compare and a pair-attempt rate limit.
- **GREEN**: add `crypto.timingSafeEqual` compare + a simple attempt counter.
- **VERIFY**: unit tests; e2e pairing still green.

### B7 — Transport seam for the app (F8) 🟠
- **RED**: `ConnectionController` test with a fake transport verifying
  reconnect-replay of subs and mDNS-rediscovery-on-stall without real sockets.
- **GREEN**: extract a `Transport` interface; inject `WsClient` (prod) /
  `FakeTransport` (test) — `FakeServer` already proves the pattern.
- **VERIFY**: unit tests.

### B8 — Observability pass (F9) 🟡
- **GREEN**: a tiny leveled logger each side (`debug/info/warn/error`, env-gated);
  replace scattered prints. Strip `[pi.line]`, `_appendEvent`, `build` spam.
- **VERIFY**: `analyze`/`tsc` clean; logs quiet at default level.

### B9 — YAGNI sweep (F10) 🟡
- **GREEN**: remove unused codegen deps *or* actually adopt them for DTOs
  (decide once — see B3); gate `debug.ask*` behind a dev flag; finish or drop
  `agent.thinking`/`tool.call.delta`.
- **VERIFY**: build + tests.

## 5. Testing strategy (target pyramid)

- **Unit (most):** pure reducer, codec, `DeviceRegistry`, `Session`, `WsClient`
  backoff, command handlers, adapter line-parsing (`extractResultText`).
- **Widget:** renderers, ask wizard, composer, glass (have these — keep).
- **Contract (new, cheap, high-value):** B3 round-trip fixtures — the cheapest
  insurance against the hand-mirrored protocol.
- **E2E (few, slow):** the 5 `integration_test` flows over the stub server; add
  approval + a `--mode=real` smoke. Keep this tier thin.

**Definition of done for any change:** a test that failed first now passes;
`flutter analyze` + `tsc --noEmit` clean; `tool/e2e.sh --mode stub` green.

## 6. Conventions to codify

- **Error codes**: `err` envelopes carry `{code, message}`; codes are an enum
  shared via the codec (`unauthorized`, `no_such_session`, `bad_request`, …).
- **Command handlers**: registered in a table, one function each, pure where
  possible, `Result`-returning.
- **Boundaries own parsing**: no `as`/coercion outside the codec layer.
- **Injectables**: transport, clock, storage, randomness, subprocess spawn — all
  passed in; composition root (`index.ts`, provider overrides) is the only place
  that news up the real ones.
- **No dead features**: an unfinished feature is behind a flag with a tracking
  note or it is deleted.
- **Logging**: leveled, no secrets, off by default in hot paths.

---

*Companion docs: `docs/ARCHITECTURE.md` (system design), `docs/UI-TRANSPORT.md`
(ctx.ui.* interceptor), `docs/CONNECTORS.md`. This file is the "how we build"
layer on top of them.*
