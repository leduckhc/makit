# SPEC-03 — macOS desktop control app

**Status:** ready · **Depends on:** SPEC-01 (control protocol) · **Blocks:** —

## Goal

A native-feeling **macOS desktop app** that is the primary, non-terminal way to
run and manage pino: a **menubar/tray** presence plus a window that can show and
**refresh the QR**, **re-pair**, list/revoke **connected devices**, show the live
**session list** with **per-session logs**, **start/stop** the server, and raise
**notifications**. It talks to the pino daemon over the SPEC-01 control socket
(same machine).

## Why

Consensus #1/#3: most users want a real UI; the app should cover *everything*
(QR + re-pair, devices, sessions, logs, start/stop, notifications). The CLI
remains for power users / headless.

## Recommended approach (confirm before building)

**Reuse the existing Flutter app as a macOS desktop build** (`app/`), because it
already speaks the pino WS protocol and has the session/chat/tool UI, models, and
store. The desktop build adds a **control layer** that talks to the SPEC-01 unix
socket for control-plane actions (start/stop, QR, devices), while reusing the WS
client (against `wss://127.0.0.1:<port>`, trusted locally) for session/log views.

- Menubar presence via a Flutter macOS tray plugin (e.g. `tray_manager` +
  `window_manager`), or a thin native Swift `NSStatusItem` shell hosting the
  Flutter view. **Decision point** — pick one; native `NSStatusItem` gives the
  best menubar UX, `tray_manager` maximizes code reuse.

Alternative (if Flutter-desktop friction is high): a small native SwiftUI menubar
app that only does the control-plane (QR/devices/start-stop) and deep-links to
the phone app for sessions. Note the tradeoff (less reuse, two codebases).

> This spec deliberately leaves the exact tech pick as the first task for the
> implementing agent to confirm with a short spike; everything below is
> tech-agnostic requirements.

## Scope

### In
- **Menubar item**: shows server state (running/stopped, # devices, # running
  sessions). Click → menu + open window.
- **Start/Stop server**: from the menubar/window. If the daemon isn't running,
  the app can start it (spawn `pino start`) and stop it (`server.stop` verb).
- **QR panel**: render current pair QR; **Refresh** button (mint new token);
  copy URL; show fingerprint. Auto-refresh countdown if token has a TTL.
- **Devices panel**: list paired devices (label, paired/last-seen, connected
  dot); revoke.
- **Sessions panel**: live session list (title, status, project); selecting one
  shows **per-session logs / transcript** (reuse the app's session view, or a
  read-only log tail).
- **Notifications**: native notifications for key events (device paired, session
  finished/errored) — reuse the existing notification policy concepts.

### Out
- Daemon internals — SPEC-01.
- Session-spawning-in-pane behavior — SPEC-05 (the app just displays sessions).
- Windows/Linux desktop — macOS only for v1.

## Design notes / contracts consumed
- **Control-plane** (start/stop, QR, devices, status): SPEC-01 unix socket via a
  Dart FFI/socket client, or a tiny local helper. Since Dart can open unix domain
  sockets (`InternetAddress(..., type: unix)`), implement a Dart port of the
  SPEC-01 `control-client`.
- **Session/log data**: connect as a local WS client to `127.0.0.1:<port>` reusing
  `app/lib/transport` + `app/lib/store`. Local connections may auto-trust the
  cert fingerprint from `status`.
- Keep the mobile app unaffected: gate desktop-only widgets behind
  `Platform.isMacOS` / a `kIsDesktop` flag; share store/transport.

## Acceptance criteria

- [ ] App launches, shows a menubar item reflecting running/stopped state.
- [ ] Start/Stop from the app actually starts/stops the daemon (verify with
      `pino status`).
- [ ] QR panel shows a scannable code; **Refresh** mints a new token and the new
      QR pairs a device end-to-end.
- [ ] Devices panel lists real paired devices; revoke works (device can no longer
      connect).
- [ ] Sessions panel lists live sessions and can display a session's
      messages/logs.
- [ ] A native notification fires on at least one real event (e.g. device paired).
- [ ] Mobile app build is unaffected (`flutter analyze --fatal-infos` clean for
      both targets; mobile tests still pass).

## Open questions
- Menubar tech: native `NSStatusItem` shell vs `tray_manager` plugin (spike first).
- Does the desktop app *require* the daemon, or can it host the server in-process?
  Recommend: it drives the daemon (SPEC-01) rather than embedding the server, to
  keep one server implementation and match the CLI.
- Cert trust for the local WS client — reuse fingerprint from `status`.
