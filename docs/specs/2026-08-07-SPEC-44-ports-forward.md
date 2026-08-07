# SPEC-44 — Ports P4: forward a loopback port to the phone, and watch a port

**Status:** Draft · **Priority:** P3 · **Branch:** `feat/open-ports-fixup`
**Depends on:** SPEC-41 (ports scan/attribution/`PortDTO`/`ports.watch`), SPEC-22 + SPEC-33
(`server/src/media/route.ts` — authenticated HTTP over the WSS listener, the pinned
`HttpClient`, `trustLoopback`), SPEC-07/08 (actionable push, `server/src/push/`), SPEC-11
(`$MAKIT_HOME`, `project-store.ts` persistence precedent).
**Mockups:** [`mockups/open-ports.html`](../../mockups/open-ports.html) — §8 (Forward & open),
§7 second frame + §10 (watched ports), §1 (`PlugsConnected` reserved for an active forward).

**Scope (P4 — this spec):**
*protocol:* `server/src/protocol.ts` (`PortDTO.watched?`, `ForwardGrantDTO`, `CmdKind +=
"ports.forward" | "ports.forward.stop" | "ports.watchPort"`), `server/src/protocol/codec.ts`
(no new event kinds — see D7/D8).
*server (P4a):* `server/src/ports/watch-store.ts` (new), `server/src/ports/watch.ts` (new —
down-detector), wiring in `server/src/ports/service.ts` + `server/src/server.ts`,
`server/src/ws/commands/ports.ts` (`ports.watchPort`).
*server (P4b):* `server/src/ports/forward-grants.ts` (new), `server/src/ports/forward-route.ts`
(new — `attachForwardRoute`), `server/src/ws/commands/ports.ts` (`ports.forward`,
`ports.forward.stop`), wiring in `server/src/server.ts`.
*app (P4a):* `app/lib/store/ports.dart` (`watched` on the model + `ports.watchPort` sender),
the "Watch this port" toggle in `app/lib/ui/ports/port_detail_sheet.dart`.
*app (P4b):* `app/lib/transport/local_forward_proxy.dart` (new — in-app loopback reverse
proxy over the pinned client), `app/lib/ui/ports/forward_confirm_sheet.dart` +
`app/lib/ui/ports/forward_webview.dart` (new), a new `webview_flutter` dependency.
*docs:* `docs/UX.md`.

---

## Goal

Two independent things, ordered cheapest-first:

1. **P4a — watch one port.** Opt-in per port. When a port a branch owns *stops listening* and
   stays down, send one actionable notification (`:5173 stopped listening`) rather than the
   firehose that always-on port notifications would be.
2. **P4b — forward one loopback port to the phone.** A loopback-only dev server is invisible
   from your phone. makit already holds a cert-pinned, device-authenticated session to that
   machine, so it can proxy the port over the listener that session already uses — reviewing
   the UI your agent just built, from the couch, **without opening a host port**.

## Why this belongs in makit

Every other port tool can tell you the number. Only makit already owns an authenticated
encrypted channel to the machine the port lives on, so only makit can carry that port to
another device without exposing it to the café Wi-Fi. That is the whole payoff, and it is the
mockup's "the one thing only makit can do."

## The transport precedent that rewrites the mockup

The mockup's scope flag (§8) calls forwarding *"a real new transport path (multiplexed HTTP
over the WSS session)."* **That is superseded, and this spec supersedes it (D1).**
`server/src/media/route.ts` already serves authenticated plain HTTP — `GET`/`HEAD`/`POST` with
byte-range streaming — over the *same* HTTPS listener(s) that carry the WebSocket, without
disturbing the `noServer` upgrade forwarding (`request` and `upgrade` are separate events),
authenticating with the paired-device bearer against the same `DeviceRegistry` the WS
handshake uses, installed on both the external and loopback listeners, honouring
`trustLoopback` for `--no-auth` dev. Forwarding is that pattern again — one more `request`
handler — not a new byte-stream multiplex inside the message-framed `codec.ts`.

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| D1 | **Transport is an HTTP proxy route (`attachForwardRoute`) on the existing HTTPS listener(s)**, reusing the paired-device bearer + `DeviceRegistry` + `trustLoopback`, **not** a new multiplexed channel inside the WSS frame protocol. The mockup's "multiplexed HTTP over the WSS session" is explicitly superseded. | `attachMediaRoute` already proves authenticated HTTP over that listener is safe and cheap. Node pipes streaming/chunked bodies and forwards arbitrary verbs natively (`createReadStream(...).pipe(res)` in the media route is the same primitive); reimplementing request/response, half-close and backpressure as frames inside `codec.ts` (a *message* protocol, not a byte stream) would be reinventing HTTP badly, for no gain. Both approaches open **no host port** equally — the route runs on the already-bound listener and dials the dev server with an *outbound* loopback socket. |
| D2 | **The phone consumer is an in-app loopback reverse-proxy, not a WebView pointed at the desktop.** The app runs a `dart:io HttpServer` on `127.0.0.1:0` (on the phone); the WebView loads `http://127.0.0.1:<appPort>/…`; the proxy re-issues each request over `pinnedHttpClient(fingerprint)` with the bearer header to the desktop forward route. | **This is the design's weakest joint, and the investigation refuted the naive WebView.** A platform WebView (WKWebView / Android WebView) uses the OS network stack and OS trust store: (a) it rejects makit's pinned self-signed cert — there is no cross-platform WebView API to inject a per-host pin, and the app's whole media story exists (`media_client.dart`: *"Flutter's `Image.network` … would reject the cert … that is why makit fetches bytes itself"*) precisely because of this; (b) it does not attach the bearer `Authorization` header to sub-resource / XHR / fetch requests. So a WebView **cannot** authenticate to the desktop without a capability in the URL — the exact thing `route.ts` rejected. The loopback proxy keeps the media route's property intact: the only URL the WebView, its history, or a screenshot ever sees is loopback on the phone; the bearer and the pinned cert stay inside the Dart HTTP client. |
| D3 | **A grant is `{ grantId, deviceId, port, worktreePath, createdAt, expiresAt, lastSeenAt }`, in-memory only, minted by `ports.forward`, keyed by an unguessable `grantId` (32 random bytes, base64url).** It does **not** survive a server restart; it is **not** bound to a WS socket (survives a reconnect); it is revoked by `ports.forward.stop`, by TTL (`FORWARD_TTL_MS` = 30 min, hard cap), by idle reap (`FORWARD_IDLE_MS` = 60 s with no proxied request), and by the device unpairing. A request against an expired/unknown/foreign grant is **403**. | Per-device + per-port + TTL is the mockup's contract. In-memory is honest: a restart proxies nothing, the WebView shows connection-refused, the app re-requests — safer than resurrecting a forward the user has forgotten. "As long as the sheet stays open" cannot mean "until an explicit close" because a WebView keeps loading assets after the sheet is gone; it is defined operationally as **activity within `FORWARD_IDLE_MS`**, so a closed sheet (no more requests) reaps within a minute even if the `stop` was lost. 403 (not 404) because the caller *is* authenticated — the grant, not the resource, is what's gone. |
| D4 | **A port may be forwarded only if it passes every rule**, each testable: (1) `reach === "loopback"`; (2) `worktreePath` is set; (3) `openUrl` is present (it answered HTTP under SPEC-41's probe); (4) it is not the server's own `port`; (5) its port is not in `NO_HTTP_PROBE_PORTS` (22, 5432, 3306, 6379, 27017, 11211). A `ports.forward` that fails any rule is refused with a one-line reason, minting no grant. | (1) an `exposed`/`tailnet` port is already reachable — forwarding is pointless. (2)+(3) forwarding proxies HTTP, so forwarding something unowned or that never spoke HTTP is guaranteed-broken; owned + probed is the same trust boundary SPEC-41 D3 already drew. (4) self-proxy is a loop. (5) the database deny-list is exactly the "assumed loopback-only, no auth of its own" services the threat model (D6) is about — refused outright, not merely unprobed. |
| D5 | **P4b proxies HTTP only. The HMR WebSocket upgrade is refused (426/close), not half-proxied.** Streaming and chunked responses (incl. `text/event-stream`) and all verbs (GET/POST/PUT/DELETE/PATCH) are forwarded. `Location` headers pointing at the target loopback `host:port` are rewritten to the proxy origin; other absolute hosts pass through unchanged; `Set-Cookie` `Domain`/`Secure` attributes tied to the target origin are stripped (the proxy is http-on-loopback). | A half-working HMR is worse than an honestly refused one: Vite/webpack compute the HMR socket URL from `location`, so behind a proxy the client dials the wrong `ws://` and silently degrades. So live-reload **does not work**; the preview is a snapshot and pull-to-refresh reloads it. Refusing the upgrade makes that failure loud and local instead of a mystery. Streaming falls straight out of piping the upstream response to `res`, exactly as the media `GET` already streams a file. |
| D6 | **Forwarding requires an explicit per-forward opt-in beyond pairing (the confirm sheet); makit never forwards ambiently.** Non-HTTP ports are refused outright (D4.5). | Threat model, stated honestly: a paired device is already trusted with the agent's full filesystem and shell, so the *device* is not the new risk. The new exposure is that a service which assumed it was loopback-only — a DB admin UI, an unauthenticated dev tool — becomes reachable by that one device for a TTL. Mitigations, in order: only worktree-owned HTTP dev servers are eligible (D4), databases are refused (D4.5), every forward is a deliberate tap on a confirm sheet, the grant is TTL'd and idle-reaped (D3), and nothing new is bound on the host (D1). |
| D7 | **A watched port is identified by `(worktreePath, port)`, never by the SPEC-41 snapshot `key`.** It is persisted in `$MAKIT_HOME/watched-ports.json` (override `MAKIT_WATCHED_PORTS_FILE`) via the `project-store.ts` pattern: load/save never throw, a corrupt/missing file degrades to empty. | SPEC-41 D6 forbids persisting `key` (`<pid>:<address>:<port>`) — a PID is reused and a restart changes it for the same endpoint. `(worktreePath, port)` is the identity that is stable across a dev-server restart, which is the whole point of watching. `project-store.ts` is the proven "never throws, degrades to empty" JSON-under-`$MAKIT_HOME` precedent, so the watch list can never break startup. |
| D8 | **A watched port fires exactly one notification only after it has been continuously absent-or-`refused` for `WATCH_DOWN_GRACE_MS` (20 s ≈ 5 scan ticks). A recovery inside the grace window cancels the pending notification and re-arms.** Delivery reuses `server/src/push/` (`PushSender` + an actionable payload); no new push mechanism. There is **no** new wire event. | This is the concrete anti-firehose rule §10 demands: "a build restarts its dev server ten times an hour", so a bare down→notify would fire on every rebuild. The grace window makes "stopped listening" mean *actually gone*, not *bouncing*. Reusing the existing sender is YAGNI; inventing a second notification path would duplicate SPEC-07/08. |
| D9 | **The notification's only action is "Ignore this port" (stop watching) + open-app. "Restart" (mockup §7) is deferred.** | Restarting a dev server *spawns a process*; SPEC-41 P1 deferred every process signal, and P3 only reaches as far as *kill*. Shipping "Restart" here would smuggle remote process-spawn into the forwarding phase. Ignore is pure state (drop the watch), which is safe and sufficient. Recorded so the missing button reads as a decision. |
| D10 | **The `PlugsConnected` glyph (SPEC-41 §1 reserved it) marks an active forward, and only that.** It appears in the forward WebView's app-bar; the worktree-row glyph stays `Plug`. | The mockup reserved two-plugs-joined for "literally what's happening" — a live tunnel to the phone. Using it anywhere else (e.g. a merely-listening port) would spend the one glyph that means *forwarding is live now*. |

## Phasing inside P4

| Phase | Content | Depends on |
| --- | --- | --- |
| **P4a** | watched ports + the "stopped listening" notification (D7–D9) | SPEC-41 snapshot only |
| **P4b** | forward-to-phone: `attachForwardRoute`, grants, the in-app proxy, confirm sheet + WebView (D1–D6, D10) | SPEC-22/33 media transport |

P4a ships first: it is independent of forwarding, an order of magnitude cheaper, and touches
no new transport or dependency. P4b is the expensive half and can slip without blocking P4a.

**On SPEC-42/43:** neither exists in the repo today, so **P4 declares no hard dependency on
them.** P4a builds only on SPEC-41's published snapshot; P4b builds only on the SPEC-22/33
media-route transport. If SPEC-42 (a global Ports screen) or SPEC-43 land later, the forward
action and the watch toggle are per-`PortDTO` and will mount there unchanged — but nothing
here waits on them.

## Wire contract

```ts
// PortDTO gains one optional, backward-compatible field (SPEC-41's tolerant
// decode drops what it doesn't know; an absent value means "not watched").
export interface PortDTO {
  // …all SPEC-41 fields unchanged…
  /** True when (worktreePath, port) is in the persisted watch list (D7).
   *  Absent ⇒ not watched. Only meaningful for a currently-listening port. */
  watched?: boolean;
}

/** A minted forward grant, returned in the `ports.forward` ack (D3). */
export interface ForwardGrantDTO {
  /** Opaque, unguessable. The path segment the in-app proxy targets; never
   *  shown to the WebView (D2). */
  grantId: string;
  /** The loopback port being proxied. */
  port: number;
  /** Epoch ms the grant hard-expires (createdAt + FORWARD_TTL_MS). */
  expiresAt: number;
}

export type CmdKind =
  // …existing…
  /** Mint a forward grant for a loopback, worktree-owned, HTTP port (D3/D4).
   *  `{worktreePath, port}`; acks `{grant: ForwardGrantDTO}` or errs with a
   *  refusal reason. */
  | "ports.forward"
  /** Revoke a grant early (Stop, sheet closed). `{grantId}`; always acks. */
  | "ports.forward.stop"
  /** Toggle the persisted watch for one port (D7). `{worktreePath, port, on}`;
   *  acks after the store write. */
  | "ports.watchPort";
```

**No new `EventKind`, and nothing added to `HOST_ONLY_KINDS`.** `watched` rides the existing
`ports.snapshot` broadcast; grants are request/reply acks (`{ t:"ack", id, grant }`, the
`command_router` `ack(extra)` shape); the "stopped listening" alert is a push (D8), not a
session or host event. This keeps SPEC-41's frozen `snapshots.json` golden valid (an absent
optional field still round-trips) and adds no third carve-out.

### The forward route (server, P4b)

`attachForwardRoute(server, deps)` — a `request` listener for `/forward/<grantId>/<rest>`,
installed on both listeners exactly like `attachMediaRoute`, `deps = { grants, registry,
resolveTarget, trustLoopback }`:

1. **Authenticate the bearer** against `registry` (or `trustLoopback` + loopback socket) —
   the same gate as the media route. The `grantId` in the path is a *routing key, not a
   capability*: the bearer still authenticates every request, and the grant must belong to
   the authenticated `deviceId`. Both are required, which is why this is not the query-string
   capability `route.ts` rejected.
2. **Resolve the grant.** Unknown / expired / foreign-device → **403** JSON, mint nothing.
   Touch `lastSeenAt` (the idle heartbeat, D3).
3. **Refuse a WebSocket upgrade** for a forwarded path (D5) — handled in the `upgrade`
   forwarder, which returns 426 for `/forward/` and leaves the WS handshake otherwise
   untouched.
4. **Proxy** to `127.0.0.1:<grant.port>`: same method, path (minus the `/forward/<grantId>`
   prefix) + query, forwarded request headers (minus hop-by-hop), streamed request body;
   stream the upstream response back, rewriting `Location` (D5). An upstream connection
   failure is **502** (the dev server died), distinct from the 403 above.

### The in-app proxy (app, P4b)

`LocalForwardProxy` binds `HttpServer` to `127.0.0.1:0` **on the phone**, reusing the
`PairedServer` credentials the media endpoint already derives (`host`, `port`, `bearer`,
`fingerprint` — see `store/media.dart`). For each WebView request it opens
`https://<host>:<port>/forward/<grantId>/<path>` via `pinnedHttpClient(fingerprint)`, sets the
bearer header, forwards method/headers/body, streams the response back, and rewrites `Location`
to the local origin. It refuses `Upgrade: websocket` locally (D5). Closing the forward view
disposes the proxy and sends `ports.forward.stop`.

## What P4 does not do

- **No live reload / HMR.** The HMR WebSocket is refused (D5); the preview is a snapshot,
  refreshed by pull-to-refresh. This is stated up front because a half-working preview is
  worse than an honest one.
- **No forwarding of non-HTTP ports** (databases, ssh, redis…) — refused, not attempted (D4).
- **No forwarding of exposed/tailnet ports** — already reachable, so pointless (D4).
- **No always-on / ambient forwarding.** Every forward is one explicit tap (D6).
- **No "Restart" from the notification** — that spawns a process (D9).
- **No always-on port notifications** — watching is per-port opt-in only (§10, D8).
- **No cross-device grant sharing, no grant persistence across a server restart** (D3).
- **No system-browser hand-off** — a system browser can neither trust the pinned cert nor
  reach the phone-local proxy origin usefully; the in-app WebView is the only surface (D2).
- **No global Ports screen, no menubar, no orphan/collision detection** — SPEC-42 territory.

## Cost — the most expensive frame on the page

P4a is cheap: two new server files, one store, one command, one model field, one toggle.
P4b is the opposite and the spec says so plainly. It adds a *new external dependency*
(`webview_flutter`), a *new in-process HTTP server on the client* (`LocalForwardProxy` — a
reverse proxy with its own connection lifecycle, header hygiene and `Location` rewriting), a
*new grant subsystem* on the server, and a *WebView UI* with a live countdown. The proxy hop
chain (WebView → phone-loopback → pinned WSS listener → desktop-loopback → dev server) is four
links, each a place a header or a stream can go wrong. That is why P4b is phased after P4a and
flagged here rather than buried.

## Tests

| Layer | Test |
| --- | --- |
| `protocol/contract.test.ts` | SPEC-41's `snapshots.json` golden still round-trips with `PortDTO.watched` absent; a snapshot **with** `watched:true` round-trips; `decodeSessionEvent` still rejects `ports.snapshot`; no new `HOST_ONLY_KINDS` entry |
| `ports/watch-store.test.ts` | `load` of a missing/corrupt file → `[]` (never throws); round-trip of `{worktreePath, port}` records; a legacy/garbled entry is skipped, the rest kept; `save` failure is swallowed + logged; env override honoured |
| `ports/watch.test.ts` | a watched port present in the snapshot arms nothing; its **first** absent tick starts the grace timer; recovery inside `WATCH_DOWN_GRACE_MS` cancels it (no notify — the bounce case); absent for the full window fires **exactly one** notify; a still-listening-but-`refused` port counts as down; an **unwatched** port never notifies; a second down after recovery re-arms |
| `ports/service.test.ts` (extend) | the snapshot marks `watched:true` for a listening port in the store and omits it otherwise; adding/removing a watch changes the next snapshot; the down-detector is fed every scan while any watch exists **and** does no work when the watch list is empty |
| `ports/forward-grants.test.ts` | mint returns an unguessable id; `get` of an unknown/expired/foreign-device id → null; TTL expiry via injected clock; idle reap after `FORWARD_IDLE_MS` with no `touch`; `stop` revokes; a device unpair drops its grants; two devices get independent grants for the same port |
| `ports/forward-route.test.ts` | **real `http.Server` on loopback stands in for the dev server** (as `media/route.test.ts` does): a GET is proxied byte-for-byte; a POST body + non-GET verbs pass through; a chunked/streamed response streams (no full buffering); `Location: http://127.0.0.1:<devPort>/x` is rewritten, a foreign-host `Location` is not; a `Set-Cookie` `Domain`/`Secure` is stripped; a missing bearer → 401; a valid bearer + unknown grant → 403; a valid grant for a **dead** upstream → 502; a `ports.forward`-refused port is never routable; an `Upgrade: websocket` → 426 |
| `ws/commands/ports.test.ts` (extend) | `ports.forward` on a loopback+owned+`openUrl` port acks a grant; each refusal rule (exposed, unowned, no `openUrl`, own port, deny-listed) errs with a reason and mints nothing; `ports.forward.stop` acks and revokes; `ports.watchPort {on:true/false}` acks and mutates the store; a malformed payload is a no-op |
| `store/ports_test.dart` (extend) | `fromJson` reads `watched`; absent stays absent (not `false`-vs-unknown confusion, per the `BudgetBucket` rule); `PortsWatchPort` sends one `ports.watchPort` per toggle |
| `transport/local_forward_proxy_test.dart` | drive the proxy with a **fake pinned endpoint** (a loopback `HttpServer` standing in for the desktop route): a request is re-issued with the bearer header and the grant path; the response streams back; `Location` is rewritten to the local origin; a local `Upgrade: websocket` is refused; dispose closes the server and sends `stop` |
| `ui/ports/forward_test.dart` | the confirm sheet shows only for a loopback port with `openUrl`; "Forward for 30 min" mints a grant then opens the WebView; the countdown counts down from `expiresAt`; Stop disposes + sends `stop`; the app-bar uses `PlugsConnected` (D10) |
| `ui/ports/port_detail_sheet_test.dart` (extend) | the "Watch this port" toggle reflects `watched` and sends `ports.watchPort`; "Forward & open" is hidden when `openUrl` is absent |
| `integration_test/stub/ports_forward_test.dart` | full-stack over the keyless stub: seed a loopback worktree-owned HTTP port → confirm → the in-app proxy serves the stubbed dev server's bytes inside the WebView; Stop tears it down |

## Verification (beyond unit tests)

Per `makit-verify-feature-end-to-end`, these can pass while the feature is dead:

1. `cd server && node_modules/.bin/tsc -p . --noEmit && pnpm test`
2. `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub`
3. **P4a live:** `pnpm exec tsx test/e2e-server.ts --mode stub` publishing a watched port,
   then flip its listener off and confirm the down-detector fires once after the grace window
   (and *not* on a quick bounce).
4. **P4b live:** start a real `vite`/`python -m http.server` on `127.0.0.1`, pair a device,
   forward it, and load the page inside the WebView on a second machine/simulator — confirm no
   new listener appears on the host (`lsof -nP -iTCP -sTCP:LISTEN` before/after is identical
   but for the outbound proxy socket) and that revocation/expiry returns 403 to the WebView.
5. A human eyeball on (4): the preview renders, and HMR is confirmed *not* connecting (D5) —
   editing a file does not live-update; a manual refresh does.
