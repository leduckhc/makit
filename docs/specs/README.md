# makit — Specs (Daemon, CLI, Desktop App, Multiplexer Sessions)

These specs capture a brainstorming consensus (2026-07) to evolve makit from a
clunky foreground CLI into a **background service** with two first-class control
surfaces (a power-user CLI and a macOS desktop app), and to make phone-initiated
sessions spawn as **attachable background panes** in the user's terminal
multiplexer.

Each spec is written to be handed to a **separate agent**. They share contracts
but are otherwise independently implementable. Respect the dependency order.

## Consensus decisions (source of truth)

1. **CLI = power users + headless/UI-less servers.** The desktop app is the
   primary surface for most day-to-day use; the CLI must remain fully capable.
2. **makit runs as a background service, but the user starts/stops it on demand.**
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
| [SPEC-01](./2026-07-05-SPEC-01-daemon-control-plane.md) | makit daemon & local control plane | — (foundation) |
| [SPEC-02](./2026-07-05-SPEC-02-cli-client-subcommands.md) | CLI client subcommands | SPEC-01 |
| [SPEC-03](./2026-07-05-SPEC-03-desktop-control-app.md) | macOS desktop **control** app (Flutter reuse; done — Phase 1 via PR #11, Phase 4 via PR #16) | SPEC-01 |
| [SPEC-04](./2026-07-05-SPEC-04-multiplexer-adapter-layer.md) | Multiplexer adapter layer + herdr | — (foundation) |
| [SPEC-05](./2026-07-05-SPEC-05-session-in-pane-spawning.md) | Session-in-pane spawning + lifecycle | **Retired — superseded by SPEC-27** (pi-over-ACP, headless) |
| [SPEC-06](./2026-07-07-SPEC-06-composer-adaptive-input.md) | Composer: adaptive input bar + send-on-content | — |
| [SPEC-08](./2026-07-08-SPEC-08-actionable-notifications.md) | Slice 1: actionable notifications (approve/reply from lock screen) | **Done** |
| [SPEC-07](./2026-07-08-SPEC-07-background-wake-notifications.md) | Slice 2: background wake for notifications (force-quit push) | **Done** (requires `push.json`; see [PUSH.md](../PUSH.md)) |
| [SPEC-10](./2026-07-12-SPEC-10-desktop-chat-app.md) | makit **desktop chat app** (chat-first macOS client; multi-harness; git/PR roadmap) | SPEC-01, SPEC-03, mobile chat stack |
| [SPEC-11](./2026-07-12-SPEC-11-repo-centric-home.md) | Repo-centric mobile home (worktrees, diff stats, PRs) | SPEC-05, SPEC-06 |
| [SPEC-20](./2026-07-17-SPEC-20-worktree-scoped-panes.md) | Worktree-scoped pane layouts | **Superseded by SPEC-28** |
| [SPEC-26](./2026-07-24-SPEC-26-acp-config-options-unified-composer.md) | ACP `configOptions` + unified composer config model (build first) | SPEC-15 |
| [SPEC-27](./2026-07-24-SPEC-27-new-session-config-at-spawn.md) | New-session config at spawn (worktree · harness · config options; desktop dialog + mobile sheet; **cached capability catalog**; native pi/mux-pane removed — pi over `pi-acp`, codex over `app-server`, projected into one config model) | SPEC-26, SPEC-10 |
| [SPEC-28](./2026-07-24-SPEC-28-desktop-workspace-tabs.md) | Desktop/iPad workspace: recursive splits + tabs (supersedes SPEC-20) | SPEC-10, SPEC-19, SPEC-27 |
| [SPEC-30](./2026-07-29-SPEC-30-tab-groups.md) ([plan](./2026-07-29-SPEC-30-PLAN.md)) | **Tab groups**: worktree groups (derived membership) + boards (curated, cross-repo); per-group layouts, three closes, recently closed boards (amends SPEC-28 decisions 3 & 6) | SPEC-28, SPEC-27, SPEC-29 |
| [SPEC-29](./2026-07-26-SPEC-29-session-lifecycle-resume-list-delete.md) | Adapter-native session lifecycle: resume (ACP `session/load`\|`session/resume`, codex `thread/resume`), list, delete, fork — fixes server-restart resume for pi **and** codex | SPEC-27, SPEC-17, SPEC-19 |

```text
SPEC-01 ─┬─> SPEC-02 (CLI clients)
         └─> SPEC-03 (desktop app)
SPEC-04 ───> SPEC-05 (spawn pi in pane — RETIRED by SPEC-27)

# Current workspace/config wave (build in order):
SPEC-26 (ACP configOptions) ──> SPEC-27 (new-session config) ──> SPEC-28 (workspace tabs)
                                                             └──> SPEC-30 (tab groups)
```

SPEC-01 and SPEC-04 can start in parallel. SPEC-02/03 need SPEC-01's control
contract frozen. SPEC-26 → SPEC-27 → SPEC-28 is the required build order for the
current wave (each depends on the prior). SPEC-05 is retired (pi is now headless
ACP via `pi-acp`, no mux pane).

## Next milestones (brainstorm — not yet specced)

Raw ideas captured for the next wave, reframed as outcomes. These are **not
frozen specs** yet; each needs its own SPEC before implementation. Numbering is
provisional.

| # | Working title | Outcome (why it matters) | Open questions |
|---|---------------|--------------------------|----------------|
| M1 | **First-run onboarding wizard (iOS)** | A brand-new user gets from *installed* → *paired* → *first message* without getting stuck. Frame it as a **stateful readiness wizard** (`reachable? → paired? → notifications granted? → ready`) that shows the one concrete fix for whatever step is failing — not a passive screenshot carousel (carousels get swiped past, go stale, and can't clear the real blockers, which are connection/permission gates). | Wizard vs. carousel split: keep any screenshot carousel as a **marketing/App Store asset** (see M2), and make the *in-app* onboarding functional/live. Which prerequisites can the app actually detect on-device? |
| M2 | **getmakit.dev marketing site** | A real landing page that explains the value prop, shows the product, and drives installs (Mac app + TestFlight/App Store). This is also the natural home for a screenshot/video carousel and the "sell" narrative. | Static vs. framework? Where do install artifacts + docs live? Does the "README that sells" (M5) get folded in here or stay separate? |
| M3 | **macOS app distribution & install** | Users install Makit.app **without building from source** — a signed + notarized artifact (DMG or similar), ideally with the `makit` CLI bundled into `Contents/Resources/` so it's zero-install (the resolver's preferred path). Removes today's `~/.local/bin/makit` dev shim. **The install must also expose the `makit` CLI on the user's PATH** — many users are CLI-first or run headless, so shipping the app should make the CLI available too (e.g. a VS-Code-style "Install `makit` command in PATH" action, or a symlink into `/usr/local/bin`), not lock the CLI away inside the bundle. | DMG vs. Sparkle auto-update vs. Homebrew cask? Signing = `Developer ID Application` under `RT8DP44B6N`. How to bundle/version the CLI inside the app? PATH exposure: opt-in menu action vs. automatic symlink vs. Homebrew formula that installs both? Keep the bundled CLI and the PATH `makit` the same build to avoid version skew. |
| M4 | **macOS control-app UX/UI polish** | The tray/control app feels like a finished product: clear server state, one-tap start/stop, device management, live sessions, QR, and notification controls — coherent visual design, not a functional-but-rough utility. | Menu-bar-only vs. a real settings window? What's the minimum surface that feels "done"? Depends on M3 for a real install story. |
| M5 | **README that sells** | The repo's front door converts a curious visitor into a user: crisp value prop, a hero demo (GIF/video), quickstart, and the Tailscale-first story — less "internal notes," more "product pitch." | Standalone rewrite, or does it become a thin pointer to the M2 site? Keep engineering detail in `docs/`. |
| M6 | **Mirror extension install & symlink reconciliation** | The `makit-mirror` pi extension mirrors a user-launched `pi` (World D) to the phone. Today `makit serve` symlinks it into `~/.pi/agent/extensions/`, but nothing **removes stale/renamed links** — e.g. the Pino→Makit rename left a dangling `pino-mirror.ts` pointing at a deleted repo, which silently breaks mirroring (phone edits never reach the CLI session). Make installation **self-healing**: reconcile the extensions dir (prune dangling + superseded `*-mirror.ts` links, keep exactly one), and let the **macOS app own the install** as a first-class action ("Install pi mirror extension" / repair), so mirroring isn't dependent on having run the server from a source checkout. | Server-side `ensureMirrorExtensionInstalled()` cleanup vs. app-driven install — or both (shared helper)? How to detect *superseded* links (any dangling symlink in the dir, or only known old brand names)? Should the app verify the link resolves + points at the bundled extension on every launch? Version skew between a bundled extension and a dev checkout's copy. Also: expose mirroring as an explicit **on/off toggle** (per-session or global) rather than always-on whenever `makit serve` is running. |

**Rough sequencing:** M3 (installable app) unblocks M4 (polish worth shipping) and
gives M2/M5 something real to link to. M1 can proceed independently once pairing
UX is stable. M2 and M5 share the same "sell" narrative and should be written
together. M6 pairs naturally with M4 (the tray app is where the install/repair UI
lives) but the symlink-reconciliation fix is independent and worth landing sooner
since stale links break mirroring silently.

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
  `~/.makit/{server.crt,server.key,devices.json,host.json,projects.json}`.
- World-D mirror extension: `server/extensions/makit-mirror.ts` (auto-symlinked
  into every `pi`; `host.open` self-registers a session).
- App: `app/lib/{transport,store,ui}`; shares the WS protocol with the server.
