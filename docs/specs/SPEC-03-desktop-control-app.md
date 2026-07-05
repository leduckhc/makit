# SPEC-03 — macOS desktop control app

**Status:** in progress (Phase 1 merged via PR #11; Phase 4 integration remaining) · **Depends on:** SPEC-01 (control protocol) · **Blocks:** —

**→ Detailed architecture & work plan:** [`../SPEC-03-ARCHITECTURE-AND-PLAN.md`](../SPEC-03-ARCHITECTURE-AND-PLAN.md)

## Goal

A macOS desktop app that lets a user **run and control the pino server** from a
menubar item plus a window. It is the *server operator's* UI: start/stop/restart
the server, show and regenerate the pairing **QR code** for phones to scan, and
list/revoke paired devices. It talks to the running pino daemon over the SPEC-01
unix control socket (`~/.pino/control.sock`, same machine).

## Why

Building the macOS target from the Flutter phone app makes it boot into the
**client onboarding flow** (scan a QR / submit a server URL) — it behaves like a
phone looking for a server to pair *to*. That is the wrong role: the desktop app
should be the thing that *runs* the server and *hands out* QR codes. The fix is
**not** a rewrite — it is to branch the app on `Platform.isMacOS` so the macOS
build boots the desktop **control** UI instead of the mobile client flow.

## Decisions (consensus — source of truth for this spec)

1. **Tech = reuse the Flutter app** (`app/`) as a macOS desktop build. **No native
   SwiftUI rewrite.** Phase-1 foundations are already merged (PR #11): a Dart
   NDJSON control-socket client, desktop screens, and a `tray_manager` menubar
   controller — all tested. We finish them, not restart.
2. **Scope = control-first.** Must-haves: run / restart / stop the server, show +
   regenerate the QR, list + revoke paired devices. Read-only **sessions** and
   **session-log** screens already exist from Phase 1 and are retained as a bonus
   (not the focus, not required to be perfect for v1).
3. **Form = menubar item + window** via `tray_manager` + `window_manager`.
4. **Server lifecycle = drive the daemon.** The app runs `pino start` /
   `pino stop` / `pino restart` and uses the control socket for everything else.
   One server implementation (SPEC-01); the app does **not** embed a server.
5. **"Invalidate mobile sessions" = revoke a paired device** (`devices.revoke`).
   A revoked device can no longer connect until it re-pairs.

## Current state (as of PR #11 — Phase 1, on `main`)

Built and tested (173 tests green; mobile build unaffected):

| Layer | Path | State |
|---|---|---|
| Control-socket client | `app/lib/control/` | ✅ `PinoControlClient` speaks NDJSON over `~/.pino/control.sock`; verbs `status`, `pair.mint`, `pair.current`, `devices.list`, `devices.revoke`, `sessions.list`, `server.stop`, streaming `logs.tail` |
| Menubar tray | `app/lib/desktop/tray/` | ✅ `TrayController` with full menu (Start/Stop, Dashboard, Pair QR, Devices(N), Sessions(N), Quit), `Platform.isMacOS`-guarded |
| Desktop screens | `app/lib/desktop/screens/` | ✅ status, QR (+countdown), devices (+revoke), sessions, session-log (streaming) |
| Deps | `app/pubspec.yaml` | ✅ `tray_manager`, `window_manager`, `qr_flutter` pinned |

### The remaining gap (Phase 4 — integration)
Nothing is wired into a launchable app yet:
- **No desktop entry point.** `main.dart` never branches on `Platform.isMacOS`,
  so the macOS build still boots the mobile client (pairing) UI — this is the
  root cause of the "app asks me to scan a QR" complaint.
- **Provider not injected.** `controlClientProvider` throws
  `UnimplementedError('Set by parent')`; the real `PinoControlClient` is never
  wired into the screens.
- **Menubar never shown.** `TrayController.init()` is not called by anything.
- **Cannot start a stopped daemon.** The client has `serverStop()` but there is
  no `Process.start('pino', ['start'])` spawn path (only stop is wired).

## Locating & installing the pino CLI

The app drives the `pino` CLI, so it must find it reliably and help install it.

- **Discovery order** (first hit wins):
  1. A copy **bundled inside the `.app`** (preferred end state; see below).
  2. `$PATH` (resolved via a login shell so it matches the user's terminal).
  3. Known locations: `~/.local/bin/pino`, `/opt/homebrew/bin/pino`,
     `/usr/local/bin/pino`.
- **Bundled CLI (preferred end state):** ship the built pino CLI (and the Node
  runtime it needs) inside the app bundle so the app works with **zero install
  step**; offer a VS Code–style "Install `pino` in PATH" button. Tracked
  separately; not required for the Phase-4 milestone.
- **curl | bash installer (v1):** documented script (see issue #13) that fetches
  the repo, runs `pnpm install && pnpm build`, and symlinks `pino` into
  `~/.local/bin`. If the app can't find `pino`, it surfaces a one-click
  affordance that runs this script.
- The app must **not hard-fail** when `pino` is absent — it shows an actionable
  "install the CLI" state instead.

## Scope

### In
- **Menubar item**: reflects server state (running/stopped, # paired devices,
  # sessions). Menu: Start/Stop/Restart, open window/dashboard, Pair QR, Quit.
- **Start / Stop / Restart server**: spawn `pino start` when stopped; `pino stop`
  (or `server.stop` verb) to stop; restart = stop-if-running + start. Menubar and
  window reflect the new state.
- **QR panel**: render `pair.current`; **Regenerate** mints a fresh token via
  `pair.mint` and re-renders; show the `pino://` URL (copyable) + fingerprint;
  countdown if the token has a TTL.
- **Devices panel**: list paired devices (label, paired/last-seen, connected
  dot); **Revoke** per device via `devices.revoke`.
- **Sessions / session-log panels** (already built): read-only list + log tail.

### Out (v1)
- Daemon internals — SPEC-01.
- Session-spawning-in-pane behavior — SPEC-05.
- Windows/Linux desktop — macOS only.
- Notifications — nice-to-have, not required for the Phase-4 milestone.

## Design notes / contracts consumed
- **Control plane** over the SPEC-01 unix socket at `~/.pino/control.sock`
  (NDJSON, `{ id, verb, args? }` → `{ id, ok, data|error }`). Client:
  `app/lib/control/`. Verbs frozen in `server/src/daemon/protocol.ts`.
- **Server lifecycle** via the CLI: `pino start` / `pino stop` / `pino restart`
  (SPEC-01). The app spawns these with `Process.start` after CLI discovery.
- **QR rendering**: the daemon returns the `pino://` URL + token; the app renders
  the QR with `qr_flutter`.
- Keep the mobile app unaffected: desktop widgets gate behind `Platform.isMacOS`;
  share store/transport.

## Acceptance criteria

- [ ] macOS build boots the desktop **control** UI — **never** the scan-QR/enter-
      URL client flow. `main.dart` branches on `Platform.isMacOS`.
- [ ] Menubar item shows running/stopped state + paired-device count; clicking
      opens the window/dashboard.
- [ ] Start / Stop / Restart from the app actually starts/stops the daemon
      (verify with `pino status`), including **starting a stopped** daemon via
      `pino start`.
- [ ] QR panel shows a scannable code from `pair.current`; **Regenerate**
      (`pair.mint`) renders a new QR that pairs a real device end-to-end.
- [ ] Devices panel lists real paired devices; **Revoke** works — the device can
      no longer connect until it re-pairs.
- [ ] If `pino` is not installed, the app shows an actionable install affordance
      rather than failing.
- [ ] Mobile build unaffected (`flutter analyze --fatal-infos` clean for both
      targets; mobile tests still pass).

## Open questions
- Bundling the Node runtime for a zero-dependency `.app` vs relying on an
  installed Node — decide during the CLI-bundling task (separate from Phase 4).
- Poll `status`/`devices.list` on a timer vs a control-socket event stream —
  polling is fine for v1.
- Homebrew tap as a follow-up install channel (not required for v1).
