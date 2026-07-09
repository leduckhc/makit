# SPEC-02 — CLI client subcommands

**Status:** done · **Depends on:** SPEC-01 (control protocol) · **Blocks:** SPEC-03

## Goal

Give power users and headless/UI-less servers a complete CLI that drives a
**running** makit daemon via the control socket from SPEC-01. Chiefly: reprint /
refresh the QR and re-pair **without restarting** the server, plus inspect and
manage devices and sessions.

## Scope

### In (new subcommands, all thin clients of the SPEC-01 control socket)
- `makit qr` — fetch the current pair token (or mint one if none/expired via
  `pair.current` → fallback `pair.mint`) and render a QR in the terminal
  (`qrcode-terminal`) + print the URL and fingerprint. `--refresh` forces a new
  token (`pair.mint`). `--url-only` prints just the URL (scripting).
- `makit pair` — alias/como of `makit qr --refresh` (mint + show). Keep the
  existing one-shot behavior working when no daemon is running (fallback: it may
  print an informative error telling the user to `makit start` first, OR keep the
  legacy standalone mint — pick one and document; prefer: require a running
  daemon and error clearly).
- `makit status` — pretty-print `status` verb (pid, host:port, fingerprint,
  advertise host, paired devices, running sessions, uptime). Exit 3 if not running.
- `makit devices` — list devices (`devices.list`); `makit devices revoke <id>`
  (`devices.revoke`).
- `makit sessions` — list running sessions (`sessions.list`): id, title, status,
  project, last activity.
- `makit stop` — already defined in SPEC-01 as lifecycle; ensure it reads nicely.

### Out
- Daemon lifecycle/`start`/`service` — owned by SPEC-01.
- Any long-running interactive TUI — out of scope (keep it one-shot commands).

## Design

- New dir `server/src/cli/` already exists (`mirror.ts`). Add `qr.ts`,
  `status.ts`, `devices.ts`, `sessions.ts` — each a small function taking argv,
  using SPEC-01's exported `control-client`.
- Extend dispatch in `server/src/index.ts` `main()`.
- Shared helper `requireDaemon()` — connects to the control socket; on ECONNREFUSED
  / missing socket, prints `makit is not running — start it with 'makit start'` and
  exits 3. Reused by all client subcommands.
- QR rendering stays terminal-side (`qrcode-terminal`), consuming the URL from
  `pair.*` verbs. Do **not** duplicate token minting logic — always go through the
  daemon so the running server honors the token.

## Acceptance criteria

- [ ] With a daemon running: `makit qr` shows a scannable QR + URL; scanning pairs
      a device end-to-end.
- [ ] `makit qr --refresh` mints a *new* token (old one no longer needed); prior
      QR reprint via `makit qr` shows the current active token.
- [ ] `makit status` matches reality (cross-check against `makit sessions` and a
      known paired device).
- [ ] `makit devices` lists paired devices; `makit devices revoke <id>` removes one
      and a subsequent connect with that bearer is rejected.
- [ ] `makit sessions` lists live sessions with correct titles/status.
- [ ] Every client subcommand, when the daemon is down, prints the standard
      "not running" message and exits 3 (no stack traces).
- [ ] `--url-only` emits exactly the URL (newline) and nothing else.
- [ ] Unit tests: argv parsing per subcommand; `requireDaemon` error path; render
      path fed a canned `pair.*` response (assert URL + fingerprint printed).
      `pnpm test` green, `pnpm typecheck` clean.

## Open questions

- `makit pair` semantics when no daemon: hard-error (recommended, simplest) vs
  legacy standalone mint. Pick hard-error unless there's a strong headless reason.
- Should `makit qr` auto-watch for a scan and print "paired ✓" then exit? Nice, but
  needs a control-plane event/push. Defer to v2 unless trivial via `logs.tail`.
