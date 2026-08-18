# SPEC-ports-forward — Implementation plan (P4)

Spec: [`20260807-004400-SPEC-ports-forward.md`](./20260807-004400-SPEC-ports-forward.md) ·
Mockups: [`mockups/open-ports.html`](../../mockups/open-ports.html)

Ground rules (AGENTS.md): **failing test first**, SOLID/YAGNI, surgical diffs, match existing
style. Commands are the repo-supported ones from [`docs/DEVELOPMENT.md`](../DEVELOPMENT.md):
`pnpm test` / `pnpm typecheck` in `server/`, `flutter test --no-pub` /
`flutter analyze --fatal-infos --no-pub` in `app/`. Two caveats that cost real time: never
`pnpm exec tsx --test` (it prunes devDependencies and hangs — use `pnpm test`, or
`node --import tsx --test <file>` for one file), and where `flutter` is not on `PATH` use the
absolute binary (AGENTS.md records `~/flutter/bin/flutter` for the Linux VM).

D1–D10 in the spec are **locked**; there is no decision gate left in this plan.

## Order — P4a fully before P4b

P4a (watched ports) is independent, cheap, and ships on its own; P4b (forwarding) is the
expensive half and must not block it. The forward route's contract test is written before its
route, and the in-app proxy before the WebView that drives it.

```
P4a  T1 protocol(watched) + red contract ─▶ T2 watch-store ─▶ T3 watch(down-detector)
        ─▶ T4 service+snapshot wiring ─▶ T5 ports.watchPort cmd ─▶ T6 push delivery
        ─▶ T7 app: watched model + toggle
─────────────────────────────────────────────────────────────────────────────────────
P4b  T8 protocol(forward DTO/cmds) + red contract ─▶ T9 forward-grants
        ─▶ T10 forward-route (red route test on a real loopback server) ─▶ T11 upgrade-refuse
        ─▶ T12 ports.forward / .stop cmds + wiring
        ─▶ T13 app: LocalForwardProxy ─▶ T14 confirm sheet + WebView ─▶ T15 e2e + docs
```

Each task states its **red test** and its **verify** command. A task is not done until its
verify passes and the whole suite still does.

---

## P4a — watched ports + notification

## T1 · protocol: `PortDTO.watched` + red contract test

Red: add a second `ports.snapshot` envelope to `server/test/fixtures/snapshots.json` whose
one port has `watched:true`; extend `server/test/protocol/contract.test.ts` to (a) round-trip
it via `decodeFrame`, (b) assert the **existing** golden (no `watched`) still round-trips, and
(c) re-assert `decodeSessionEvent(snapshot) === null`. Fails before the field exists.

Green: `protocol.ts` — add optional `watched?: boolean` to `PortDTO` with the D7 comment. **No
new `EventKind`, no `HOST_ONLY_KINDS` change.**

Verify: `cd server && pnpm test -- --test-name-pattern=contract && node_modules/.bin/tsc -p . --noEmit`.
Dart mirror lands in T7.

## T2 · `ports/watch-store.ts` — persistence

Red: `ports/watch-store.test.ts` — missing file → `[]`; corrupt JSON → `[]` (never throws); a
`{worktreePath, port}` round-trips; a malformed entry is skipped and the rest kept; a `save`
failure is swallowed + logged; `MAKIT_WATCHED_PORTS_FILE` override honoured.

Green: `loadWatchedPorts(file)` / `saveWatchedPorts(file, list)` / `watchedPortsFile()`,
copied structurally from `project-store.ts` (the proven never-throw pattern). Shape
`{ "watched": [{ "worktreePath": string, "port": number }] }`.

Verify: `pnpm test -- --test-name-pattern=watch-store`.

## T3 · `ports/watch.ts` — the down-detector (anti-firehose)

Red: `ports/watch.test.ts` with an injected clock — a watched port present in a snapshot arms
nothing; its first absent tick starts the grace timer; recovery inside `WATCH_DOWN_GRACE_MS`
cancels it (no fire — the rebuild case); absent for the full window fires **exactly one**
alert; a listening-but-`refused` port counts as down; an unwatched port never fires; a second
down after recovery re-arms.

Green: `PortsWatchDetector` — `observe(snapshot)` per scan, `{ isWatched, now, onDown }`
injected. Names `WATCH_DOWN_GRACE_MS` = 20_000 here with the §10 comment. Pure except the
injected `onDown`. Fires the port's `(worktreePath, port)` + last-known command/uptime for the
notification body.

Verify: `pnpm test -- --test-name-pattern=watch`.

## T4 · service + snapshot wiring

Red: extend `ports/service.test.ts` — a listening port in the watch store is marked
`watched:true` in the published snapshot and unmarked otherwise; the detector's `observe` is
called every scan while the store is non-empty and never when empty; the detector reads the
same snapshot that is broadcast.

Green: `PortsService` gains `{ isWatched, onPortDown }` (injected, like SPEC-open-ports's other
seams); it sets `watched` while attributing, and feeds `observe` after publish (stale-while-
revalidate, same discipline as health `refresh`).

Verify: `pnpm test -- --test-name-pattern=service` then the whole server suite.

## T5 · `ports.watchPort` command

Red: extend `ws/commands/ports.test.ts` — `{on:true}` acks after the store write and the next
snapshot marks it `watched`; `{on:false}` acks and unmarks; a malformed payload (missing
`port`, non-boolean `on`) is a no-op, not a crash.

Green: the handler in `ws/commands/ports.ts`, mutating the store via a `CommandDeps` seam
(`setWatchedPort(worktreePath, port, on)`); `CmdKind += "ports.watchPort"`.

Verify: `pnpm test` (whole server suite) + `tsc --noEmit`.

## T6 · push delivery (reuse `server/src/push/`)

Red: a `server.ts`-level test (or a focused unit around the wiring) that a `onPortDown`
callback builds an actionable payload — title `:<port> stopped listening`, body
`<command> · <branch> · was up <uptime>`, action **Ignore this port** — and hands it to the
injected `PushSender.wake` **once**; with `NoopPushSender` nothing is dispatched (parity with
the wake coordinator's short-circuit).

Green: wire `PortsWatchDetector.onDown` → an actionable APNs payload (`push/payload.ts`) →
`sender.wake`. "Ignore this port" resolves to a `ports.watchPort {on:false}` on tap (D9). **No
"Restart" action.** No new push mechanism.

Verify: `pnpm test` + `tsc --noEmit`.

## T7 · app: `watched` model + the toggle

Red: extend `test/store/ports_test.dart` (`fromJson` reads `watched`; absent stays absent) and
`test/ui/ports/port_detail_sheet_test.dart` (the "Watch this port" toggle reflects `watched`
and sends exactly one `ports.watchPort` per flip; assertions install a `SystemChannels`
mock where needed). Add the `watched:true` fixture to `codec_contract_test.dart`.

Green: `PortDTO.watched` in `store/ports.dart`; a `PortsWatchPort` sender (fire-and-forget
`send`, matching SPEC-open-ports deviation #3 — no `request` ack timer on a UI toggle); the toggle in
`port_detail_sheet.dart`. `fake_server.dart` handles `ports.watchPort`.

Verify: `flutter test --no-pub test/store/ports_test.dart test/ui/ports/ && flutter analyze --fatal-infos --no-pub`.

**P4a is shippable at the end of T7.**

---

## P4b — forward a loopback port to the phone

## T8 · protocol: forward DTO + commands + red contract

Red: extend `contract.test.ts` — a `ports.forward` ack carrying a `ForwardGrantDTO` decodes;
the DTO shape is asserted; `decodeSessionEvent` is unaffected.

Green: `protocol.ts` — `ForwardGrantDTO`; `CmdKind += "ports.forward" | "ports.forward.stop"`.
`codec.ts` unchanged (acks are not events).

Verify: `pnpm test -- --test-name-pattern=contract && tsc --noEmit`.

## T9 · `ports/forward-grants.ts` — the grant store

Red: `ports/forward-grants.test.ts` with an injected clock — `mint` returns an unguessable id
(≥32 bytes of entropy, base64url); `get(unknown)` → null; `get` of an expired grant → null;
idle reap after `FORWARD_IDLE_MS` with no `touch`; TTL hard cap at `FORWARD_TTL_MS`; `stop`
revokes; `revokeDevice(deviceId)` drops all of a device's grants; two devices get independent
grants for the same port.

Green: `ForwardGrants` — `mint({deviceId, port, worktreePath})`, `get(grantId, deviceId)`,
`touch(grantId)`, `stop(grantId)`, `revokeDevice(deviceId)`, `sweep(now)`. In-memory `Map`,
`crypto.randomBytes` for the id. Constants `FORWARD_TTL_MS` = 30*60_000, `FORWARD_IDLE_MS` =
60_000 named here.

Verify: `pnpm test -- --test-name-pattern=forward-grants`.

## T10 · `ports/forward-route.ts` — `attachForwardRoute` (red route test first)

Red: `ports/forward-route.test.ts` spins a **real `http.Server` on loopback** as the stand-in
dev server (the `media/route.test.ts` harness pattern) and a second server with
`attachForwardRoute` installed: a GET is proxied byte-for-byte; a POST body + PUT/DELETE pass
through; a chunked/streamed upstream response streams back without full buffering; a
`Location: http://127.0.0.1:<devPort>/x` is rewritten to the route origin, a foreign-host
`Location` is left alone; a `Set-Cookie` with `Domain=…`/`Secure` targeting the dev origin is
stripped; missing bearer → 401; valid bearer + unknown/foreign grant → 403; valid grant +
**dead** upstream → 502.

Green: `attachForwardRoute(server, { grants, registry, trustLoopback })` — a `request`
listener on `/forward/<grantId>/…`: authenticate (bearer or `trustLoopback`+loopback, exactly
`route.ts`'s `authorized`), resolve+`touch` the grant (else 403), open `http.request` to
`127.0.0.1:<grant.port>`, forward method/path/query/headers (minus hop-by-hop), pipe request
body up and response body down, rewrite `Location` (D5). Installed on both listeners.

Verify: `pnpm test -- --test-name-pattern=forward-route`.

## T11 · refuse the HMR WebSocket upgrade (D5)

Red: a test that an `upgrade` request for a `/forward/` path is answered 426 and the socket
closed, while a normal WS upgrade (`/`) still reaches `wss.handleUpgrade`.

Green: in `server.ts`'s `forwardUpgrade`, short-circuit `req.url` starting `/forward/` with a
426 + destroy, before `wss.handleUpgrade`. One guard, both listeners.

Verify: `pnpm test -- --test-name-pattern=upgrade` + the whole server suite.

## T12 · `ports.forward` / `.stop` commands + wiring

Red: extend `ws/commands/ports.test.ts` — `ports.forward` on a loopback + `worktreePath` +
`openUrl` port acks a `ForwardGrantDTO`; **each** refusal rule (D4: exposed, unowned, no
`openUrl`, the server's own port, a deny-listed port) errs with a distinct reason and mints
nothing; `ports.forward.stop` acks and revokes (a subsequent proxied request 403s); a
malformed payload is a no-op.

Green: the two handlers in `ws/commands/ports.ts`, validating against the **cached** snapshot
(no rescan) and the server's own `port`; a `CommandDeps` seam exposing `ForwardGrants` +
`serverPort` + a snapshot lookup; `server.ts` constructs `ForwardGrants`, passes it to both
`attachForwardRoute` and the command deps, sweeps on a timer, and calls `revokeDevice` where
`watchingPorts`/sockets are already cleared on close.

Verify: `pnpm test` (whole server suite) + `tsc --noEmit`.

## T13 · app: `LocalForwardProxy`

Red: `test/transport/local_forward_proxy_test.dart` drives the proxy against a **loopback
`HttpServer` standing in for the desktop forward route**: a request is re-issued with the
bearer header at `/forward/<grantId>/<path>`; the response streams back to the caller;
`Location` from the upstream is rewritten to the local origin; a local `Upgrade: websocket` is
refused; `dispose()` closes the server. Credentials come from a `MediaEndpoint`-shaped input,
reusing `pinnedHttpClient`.

Green: `transport/local_forward_proxy.dart` — `HttpServer.bind('127.0.0.1', 0)`, per-request
forward over `pinnedHttpClient(fingerprint)` + bearer to
`https://<host>:<port>/forward/<grantId>/…`, stream both ways, rewrite `Location`, refuse local
ws (D5). Exposes `localBase` (`http://127.0.0.1:<localPort>`) and `dispose()`.

Verify: `flutter test --no-pub test/transport/local_forward_proxy_test.dart`.

## T14 · app: confirm sheet + WebView

Red: `test/ui/ports/forward_test.dart` — the confirm sheet appears only for a loopback port
with `openUrl`; "Forward for 30 min" sends `ports.forward` and, on the grant ack, opens the
WebView pointed at `localBase`; the app-bar shows `PlugsConnected` (D10) and a countdown from
`expiresAt`; Stop disposes the proxy and sends `ports.forward.stop`. (WebView itself is
mocked/injected — the widget test asserts wiring, not a real page load.)

Green: add `webview_flutter` to `pubspec.yaml`; `forward_confirm_sheet.dart` (the §8 copy,
"never opens a host port") + `forward_webview.dart` (title `makit · localhost:<port>`,
`forwarded · MM:SS left`, Stop) wired to `LocalForwardProxy` and the `ports.forward` RPC. The
"Forward & open" row in `port_detail_sheet.dart` opens the confirm sheet.

Verify: `flutter test --no-pub test/ui/ports/ && flutter analyze --fatal-infos --no-pub`.

## T15 · e2e + docs

- `test/e2e-server.ts`: expose a deterministic loopback worktree-owned HTTP port so the stub
  loop can mint a grant and proxy it.
- `integration_test/stub/ports_forward_test.dart`, registered in `all_stub_test.dart`:
  confirm → proxy serves the stubbed dev server's bytes → Stop tears down.
- `docs/UX.md`: one paragraph each — watched-port opt-in + the forward flow.

Verify: `tool/e2e.sh --mode=stub` **on macOS** (needs a simulator; cannot run on the Linux
VM). Where no simulator exists, the keyless server loop is the substitute for the server half:
`pnpm exec tsx test/e2e-server.ts --mode stub` driven by a WSS client
(`{t:"hello",bearer}` → `ports.watch` → `ports.forward`) plus a raw `fetch` through the
minted grant path.

---

## Definition of done

1. `cd server && pnpm typecheck && pnpm test` green.
2. `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub` green.
3. **P4a:** the down-detector fires **once** after the grace window and **not** on a bounce —
   asserted with an injected clock, and eyeballed on the stub loop (verification §3).
4. **P4b:** `forward-route.test.ts` proves proxy/streaming/verbs/`Location`/403/502/426
   against a real loopback server; a live forward opens **no new host listener** (verification
   §4); HMR is confirmed *not* connecting (D5, verification §5).
5. `tool/e2e.sh --mode=stub` green with both new cases listed — macOS only.
6. `dart format lib test tool integration_test` clean (**not** `dart format .` — it walks
   `build/`, where cargokit writes unformatted generated Dart; project skill).

## Deviations log

Record every departure from this plan here as it happens, with the reason (the convention
SPEC-open-ports-PLAN / SPEC-message-navigator-PLAN use). Empty at the start.

| # | Task | Deviation | Why |
| --- | --- | --- | --- |

## Risks

| Risk | Mitigation |
| --- | --- |
| A WebView silently uses its own network stack (no pin, no bearer) | D2: the WebView only ever talks to the phone-local loopback proxy; the pin + bearer live in the Dart `pinnedHttpClient`. A `local_forward_proxy_test` asserts the bearer is set on the outbound leg |
| HMR half-works and looks like a makit bug | D5: the ws upgrade is *refused* (426), so live-reload fails loudly; documented as a non-feature; verification §5 confirms it |
| A forgotten forward stays open | D3: TTL hard cap + 60 s idle reap + `revokeDevice` on unpair/close; a restart drops all grants |
| Forwarding a database admin UI with no auth of its own | D4/D6: only loopback + worktree-owned + HTTP-answering ports; the DB deny-list is refused outright; every forward is an explicit tap |
| `Location`/cookie rewriting leaks the target origin | forward-route + proxy tests pin the rewrite and the `Domain`/`Secure` strip; foreign hosts pass through unchanged (honest, not wrong) |
| `webview_flutter` is a heavy new dependency | isolated to P4b; P4a ships without it; the widget tests inject/mocking the WebView so the suite doesn't need a platform view |
| The grant path segment read as a capability | it is a routing key only — the bearer authenticates every request and the grant is device-scoped (route test: unknown grant + valid bearer → 403; valid grant + no bearer → 401) |
