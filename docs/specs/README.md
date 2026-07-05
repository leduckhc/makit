# pino — Specs (Daemon, CLI, Desktop App, Multiplexer Sessions)

These specs capture a brainstorming consensus (2026-07) to evolve pino from a
clunky foreground CLI into a **background service** with two first-class control
surfaces (a power-user CLI and a macOS desktop app), and to make phone-initiated
sessions spawn as **attachable background panes** in the user's terminal
multiplexer.

Each spec is written to be handed to a **separate agent**. They share contracts
but are otherwise independently implementable. Respect the dependency order.

## Consensus decisions (source of truth)

1. **CLI = power users + headless/UI-less servers.** The desktop app is the
   primary surface for most day-to-day use; the CLI must remain fully capable.
2. **pino runs as a background service, but the user starts/stops it on demand.**
   Not a forced always-on daemon — explicit `start`/`stop`. A login-item/launchd
   install is opt-in only.
3. **Desktop UI surface = everything discussed:** show/refresh QR, re-pair,
   connected devices (+ revoke), live session list, per-session logs, start/stop
   server, notifications.
4. **Multiplexer: herdr now; tmux/cmux someday — build a pluggable layer.**
5. **A phone-initiated session spawns pi in a new *background* (unfocused) pane**
   you can attach to; the pane **auto-closes** when the session ends/quits.
6. Deliverable: these spec files. Implementation happens later, per-spec.

## Specs & dependency graph

| Spec | Title | Depends on |
|------|-------|-----------|
| [SPEC-01](./SPEC-01-daemon-control-plane.md) | pino daemon & local control plane | — (foundation) |
| [SPEC-02](./SPEC-02-cli-client-subcommands.md) | CLI client subcommands | SPEC-01 |
| [SPEC-03](./SPEC-03-desktop-control-app.md) | macOS desktop **control** app (Flutter reuse; Phase 1 merged, Phase 4 integration remaining) | SPEC-01 |
| [SPEC-04](./SPEC-04-multiplexer-adapter-layer.md) | Multiplexer adapter layer + herdr | — (foundation) |
| [SPEC-05](./SPEC-05-session-in-pane-spawning.md) | Session-in-pane spawning + lifecycle | SPEC-04 (+ manager/extension) |

```
SPEC-01 ─┬─> SPEC-02 (CLI clients)
         └─> SPEC-03 (desktop app)
SPEC-04 ───> SPEC-05 (spawn pi in pane)
```

SPEC-01 and SPEC-04 can start in parallel. SPEC-02/03 need SPEC-01's control
contract frozen. SPEC-05 needs SPEC-04's adapter interface frozen.

## Ground rules for every spec (from AGENTS.md)

- **TDD:** a failing test precedes production logic (red → green → refactor).
- **SOLID / YAGNI:** minimum code that solves the ask; no speculative flexibility.
- **Surgical diffs:** touch only what the spec requires; match existing style.
- `server/` is **pnpm-only** (never `npm install`). `flutter analyze
  --fatal-infos` must be clean; `app/tool/audit.sh` must pass.
- Flutter binary: `/Users/le/Work/Vibe/flutter/bin/flutter` (not on PATH).
- Commit promptly (repo has a background process that can revert uncommitted
  edits; verify with `git grep <token> HEAD` after committing).

## Current-state anchors (real code the specs build on)

- CLI entry & command dispatch: `server/src/index.ts` (`main()`, `parseArgs`,
  cmds `serve|pair|attach|mirror`; `SIGUSR1` reprints a QR; `qrcode-terminal`).
- Server + command router: `server/src/server.ts` (`startWsServer`, `host.*`
  routes, `broadcastSnapshots`).
- Session manager: `server/src/manager.ts` (`spawnPiSession`, `createSession`,
  `openHostSession`).
- Pairing/cert/mDNS: `server/src/pairing/{cert,registry,url,mdns}.ts`; state in
  `~/.pino/{server.crt,server.key,devices.json,host.json,projects.json}`.
- World-D mirror extension: `server/extensions/pino-mirror.ts` (auto-symlinked
  into every `pi`; `host.open` self-registers a session).
- App: `app/lib/{transport,store,ui}`; shares the WS protocol with the server.
