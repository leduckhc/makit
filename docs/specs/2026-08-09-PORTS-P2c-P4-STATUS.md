# Ports P2c–P4 — what shipped, what did not, and the two findings

**Date:** 2026-08-09 · **Branch:** `feat/ports-next-steps`
**Covers:** SPEC-42 P2c, SPEC-43 P3a+P3b, SPEC-44 P4a, SPEC-44 P4b (server half)

This is a status record, not a spec. It exists because the ports work now spans four
specs and stopped at a deliberate line: everything whose acceptance criteria can be
checked headlessly is done and verified; the parts whose criteria are *device-based*
are not started, and are listed here precisely enough to resume cold.

---

## Shipped and verified

| Phase | Content | Proof beyond unit tests |
| --- | --- | --- |
| **SPEC-42 P2c** | `ports/docker.ts` (TTL-cached, code-checked `docker ps`), service overlay, `PortDTO.docker`, container name + `docker` token in the UI, `Ports (n)` menubar submenu with `Open Ports…` | keyless loop: `docker` annotation arrives on `ports.snapshot` with `reach` untouched |
| **SPEC-42 P2a fix** | desktop `⌘⇧P` and the worktree menu's `Ports…` used `context.go` in a shell that has **no GoRouter** — both threw at runtime while their tests passed inside a test-only router. Now `DesktopPortsRoute.open` pushes on the shell navigator | `keymap_scope_test.dart` + `desktop_sidebar_ports_menu_test.dart` rewritten to the real (routerless) shape |
| **SPEC-43 P3a** | `ports/kill.ts` (pure whitelist R1–R7), `PortsService.killPort` (SIGTERM → re-verified grace → SIGKILL), `ports.kill`, D7 audit line, desktop `Kill` (last, error-tinted, confirms even when pinned), mobile `Kill this process…` past a danger divider | `ports/kill_acceptance.test.ts` kills a **real** `node` listener in a **real** worktree; `ws/ports_kill_e2e.test.ts` covers unauthed refusal, the released row vanishing, and `not_owned` for a system listener |
| **SPEC-43 P3b** | `PortsService.killOrphans` (N independent re-verified kills), `ports.killOrphans`, `Kill all orphans (n)` behind one confirm naming the ports | per-endpoint outcome array asserted, incl. one survivor not aborting the batch |
| **SPEC-44 P4a** | `ports/watch_store.ts` (never throws), `ports/watch.ts` down-detector (20 s grace, one alert per outage, bounce-immune), `PortDTO.watched`, `ports.watchPort`, `Watch this port` switch, `buildPortDownPayload` | keyless loop: toggle → `watched-ports.json` on disk → `watched:true` on the next broadcast |
| **SPEC-44 P4b — server half** | `ports/forward_grants.ts` (unguessable id, per-device, hard TTL + idle reap), `ports/forward_eligibility.ts` (D4 rules), `ports/forward_route.ts` (`attachForwardRoute`, 401/403/502/426, `Location` rewrite, `Set-Cookie` de-origining, streaming), `ports.forward` / `ports.forward.stop` | `ws/ports_forward_e2e.test.ts` proxies a **real** loopback dev server's bytes **through the WSS listener itself** (no new host port) and proves `Stop` → 403 |
| **SPEC-44 P4b — client** | **D2 revised: the system browser, not an in-app WebView.** `browser:true` grants (id-as-capability), `Referrer-Policy: no-referrer`, `ports.forward` returns a path the client joins to its own origin, `Open in browser` **replaces** `Open` on iOS/Android for a loopback port | the e2e fetches with **no `Authorization` header** — what Safari does — over the same host/port/TLS as the WS |

Server: `tsc --noEmit` clean, `pnpm test` 1244/1244. App: `flutter analyze` clean; ports,
tray, store and codec suites green.

## Two findings worth remembering

1. **`startedAt` cannot be compared for equality.** SPEC-43 D1 says re-match all four
   tuple fields. But `startedAt` is *derived* per scan as `now - etime`, and `ps` reports
   `etime` at one-second granularity — so the same untouched process yields a `startedAt`
   that moves by up to ~1000 ms between scans (`service.ts` already excludes it from the
   broadcast dedup projection for this reason). Exact equality therefore refused **every**
   real kill; the real-listener acceptance test is what caught it, no unit test could.
   `kill.ts` now compares within `STARTED_AT_TOLERANCE_MS` (2 s) and documents why that
   keeps the pid-reuse guard meaningful.
2. **A capability decision must not read the broadcast cache.** `forwardPort` first used
   `cachedSnapshot()`, which is only advanced when the service actually *broadcasts* — so
   a forward requested while no ports list was open refused with "could not read this
   machine's sockets". `PortsService.scanNow()` now returns a fresh scan to the caller
   regardless of watchers; `killPort` already had this discipline via `doScan`.

## Decisions revised while implementing

### D2: the system browser instead of an in-app WebView — **shipped**

The user chose the system browser over the WebView, and the spec's own reasoning is
what makes that the better shape rather than a compromise:

- A WebView uses the OS network stack, so it can neither pin makit's self-signed
  cert nor attach the bearer — which is precisely why D2 called for an HTTP proxy
  **inside the app**. That proxy cannot survive the hand-off it exists for: on iOS
  the app is suspended seconds after backgrounding, i.e. the moment a browser takes
  over. The WebView could only ever have worked because it kept the app in the
  foreground.
- Handing the URL to the system browser deletes `webview_flutter`,
  `LocalForwardProxy`, the countdown UI and a native dependency (`url_launcher`
  was already present), and leaves the security work on the server where the
  tests can reach it.

What that cost, recorded so it is not rediscovered as a bug:

| Consequence | Mitigation |
| --- | --- |
| A browser cannot send `Authorization`, so the grant id **is** the capability | `browser:true` is a recorded flag, never inferred from a missing header; the id is 32 random bytes; TTL and idle reap unchanged; `Referrer-Policy: no-referrer` on every proxied response so the previewed page cannot leak its own URL |
| The cert is self-signed, so the browser shows an interstitial (≈ once per session on iOS) | Accepted deliberately (option A) to keep the "no new host port" property that the README claims and the Exposed filter verifies. The confirm sheet warns about it up front. The rejected alternative was a tailnet-bound plain-HTTP listener — no warning, but a second listener on the host |

Still worth doing later, and additive: an in-app **Stop** for a live forward (the
grant id is returned to the caller, so it is one command away), and a
`launchUrl` failure path on desktop if the Ports screen ever wants the same action.

## Not started — and why

### SPEC-44 D9 — the notification's `Ignore this port` action

The down alert currently delivers title + body only. Making the action work needs an iOS
notification category + action handler that sends `ports.watchPort {on:false}`, which in
turn needs the port in the payload's machine-readable data. That last part is a
**privacy decision**: `push/payload.ts`'s invariant is that a payload cannot carry project
content, and its test walks the payload tree asserting an allowlist. A port number is host
metadata (the same class the kill audit line logs) and would be defensible — but it should
be added together with the consumer that needs it, not speculatively.

### Left as decided-not-built (unchanged from the specs)

- Suggested free port in the collision banner — SPEC-43 D6 hands it to SPEC-42, SPEC-42
  hands it to P3. **The two specs contradict each other**; it belongs to whoever picks it
  up, and it is still unbuilt.
- The mockup's §6 exposed-filter security banner + `Copy fix` (`Bind 127.0.0.1 in
  compose.yml`). No spec owns it. It is the frame that verifies the README's "no ports
  exposed to café networks" claim, so it is worth a decision rather than silence.
- `no auth` pill, cpu/rss, `reach: docker`, auto-kill, inline mobile kill, HMR over a
  forward — all explicitly rejected by SPEC-41 D4/D5, SPEC-42 D13, SPEC-41 §10 and
  SPEC-44 D5 respectively.
