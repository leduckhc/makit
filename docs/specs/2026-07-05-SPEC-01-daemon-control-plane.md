# SPEC-01 — pino daemon & local control plane

**Status:** done · **Depends on:** none (foundation) · **Blocks:** SPEC-02, SPEC-03

## Goal

Decouple the running pino server from any single foreground terminal. Introduce
a **user-controlled background service** (explicit start/stop) plus a **local
control plane** (unix-domain socket) so other processes — the CLI (SPEC-02) and
the desktop app (SPEC-03) — can drive a *running* pino: show/refresh the QR,
re-pair, list/revoke devices, list sessions, tail logs, and stop the server —
**without restarting it**.

## Why

Today `pino serve` is a foreground process. You cannot ask a running instance to
reprint a QR (only a `SIGUSR1` hack), re-pair, or inspect state; closing the
terminal kills it. This blocks every "real UI" idea.

## Scope

### In
- Background lifecycle: `pino start`, `pino stop`, `pino restart`, `pino status`,
  `pino logs [-f]`.
  - `start` launches the existing server (`startWsServer`) **detached** from the
    controlling terminal, writes a PID file and redirects output to a log file.
  - Idempotent: `start` when already running prints status and exits 0.
- **Control socket**: a unix-domain socket at `~/.pino/control.sock` (mode 0600)
  served by the running daemon, speaking a small JSON line protocol (below).
- **Control operations** (verbs) served over the socket — see contract.
- PID file `~/.pino/pino.pid`, log file `~/.pino/pino.log` (rolled or truncated
  on start — keep simple: truncate, document it).
- Opt-in OS integration: `pino service install` / `service uninstall` writes/removes
  a macOS **launchd LaunchAgent** plist (`~/Library/LaunchAgents/dev.pino.plist`)
  with `RunAtLoad`/`KeepAlive=false`. Default install does nothing automatically
  (consensus #2: user starts/stops on demand).
- Keep `pino serve` working unchanged (foreground) for headless servers / debugging.

### Out
- CLI client verbs like `pino qr`/`pino devices` — those are **SPEC-02** (they
  are *clients* of this control socket).
- Any GUI — **SPEC-03**.
- Auth for the control socket beyond filesystem perms (local-only, 0600 is the
  boundary for v1; document the threat model).

## Design

- New module `server/src/daemon/` :
  - `service.ts` — start/stop/status/restart/logs process management. Use
    `child_process.spawn(process.execPath, [entry, "serve", ...], { detached:
    true, stdio: [ignore, logFd, logFd] })` then `unref()`. Record PID.
  - `control-server.ts` — `net.createServer` on the unix socket, wired into the
    running server. Dispatches control verbs to existing server internals
    (registry, manager, cert, mDNS). Register it from within `startWsServer` (or
    an init hook) so it has direct in-process access — **not** over WS.
  - `control-client.ts` — a tiny reusable client (`connect + request(verb, args)
    → response`) used by SPEC-02. Export it.
  - `protocol.ts` — control verb/response types (below), plus a codec.
- `server/src/index.ts`: extend `main()` dispatch with `start|stop|restart|status|
  logs|service`. Keep `serve|pair|attach|mirror`.

### Control protocol (freeze this — SPEC-02/03 depend on it)

Newline-delimited JSON over the unix socket. Request: `{ id, verb, args? }`.
Response: `{ id, ok: true, data? }` or `{ id, ok: false, error }`.

Verbs (v1):

| verb | args | data |
|------|------|------|
| `status` | — | `{ pid, uptimeMs, host, port, fingerprint, advertiseHost, pairedDevices, runningSessions, version }` |
| `pair.mint` | `{ ttlMs? }` | `{ url, token, expiresAt, fingerprint }` — mint a fresh pair token + build the pino:// URL |
| `pair.current` | — | `{ url, token, expiresAt } \| null` — the active unexpired token, if any |
| `devices.list` | — | `{ devices: [{ id, label, pairedAt, lastSeenAt, connected }] }` |
| `devices.revoke` | `{ id }` | `{ removed: boolean }` |
| `sessions.list` | — | `{ sessions: [SessionDTO] }` (reuse `Session.toDTO()`) |
| `server.stop` | — | `{ stopping: true }` (graceful shutdown) |
| `logs.tail` | `{ lines?, follow? }` | streamed lines (define framing: `{ id, ok, data:{ line } }` chunks until socket close for follow) |

QR rendering is a **client** concern (terminal vs image); the daemon returns the
URL + token, not ASCII art.

## Acceptance criteria

- [x] `pino start` returns immediately; server keeps running after the launching
      shell exits; `~/.pino/pino.pid` and `pino.log` exist.
- [x] `pino status` (calls `status` verb) prints pid/port/fingerprint/paired
      count when running; prints "not running" + exit code 3 when not.
- [x] `pino stop` triggers graceful shutdown; PID file removed; socket closed.
- [x] `pino restart` = stop (if running) + start; survives.
- [x] `pair.mint` over the socket yields a URL that pairs a real device
      end-to-end (verify with an existing paired flow / the WS probe technique).
- [x] Control socket is `0600`; connecting from another process works; a second
      `start` is a no-op that reports already-running.
- [x] `pino serve` (foreground) still works and now **also** serves the control
      socket (so `pino status`/`qr` work against a foreground instance too).
- [x] `pino service install` writes a valid launchd plist; `uninstall` removes
      it; neither auto-starts on install.
- [x] Unit tests: control codec round-trip; verb dispatch with a fake server
      backend; service start/stop/status against a stub entry. `pnpm test` green,
      `pnpm typecheck` clean.

## Open questions (resolve in-spec, note the decision)

- Log rotation vs truncate-on-start — start with truncate; document.
- `logs.tail --follow` framing — define precisely and test the chunk protocol.
- Does `server.stop` also stop sessions/panes? For v1: stop the server process;
  SPEC-05 owns pane teardown on its own session-end path.

## Notes for the implementer

- Reuse, don't rebuild: `DeviceRegistry`, `buildPairUrl`, `loadOrCreateCert`,
  `MdnsAd`, `manager.listSessions()` already exist.
- The daemon and the WS server are the **same process**; the control socket is an
  in-process side channel, not a second server.
