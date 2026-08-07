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
| [SPEC-20](./2026-07-17-SPEC-20-worktree-scoped-panes.md) | Worktree-scoped pane layouts | **Superseded by SPEC-28**; its keyed-layout *mechanism* is rehabilitated by SPEC-30 (keyed by group, not worktree) |
| [SPEC-26](./2026-07-24-SPEC-26-acp-config-options-unified-composer.md) | ACP `configOptions` + unified composer config model (build first) | SPEC-15 |
| [SPEC-27](./2026-07-24-SPEC-27-new-session-config-at-spawn.md) | New-session config at spawn (worktree · harness · config options; desktop dialog + mobile sheet; **cached capability catalog**; native pi/mux-pane removed — pi over `pi-acp`, codex over `app-server`, projected into one config model) | SPEC-26, SPEC-10 |
| [SPEC-28](./2026-07-24-SPEC-28-desktop-workspace-tabs.md) | Desktop/iPad workspace: recursive splits + tabs (supersedes SPEC-20) — **decisions 3 & 6 amended by SPEC-30** | SPEC-10, SPEC-19, SPEC-27 |
| [SPEC-30](./2026-07-29-SPEC-30-tab-groups.md) ([plan](./2026-07-29-SPEC-30-PLAN.md)) | **Tab groups**: worktree groups (derived membership) + boards (curated, cross-repo); per-group layouts, three closes, recently closed boards (amends SPEC-28 decisions 3 & 6) | SPEC-28, SPEC-27, SPEC-29 |
| [SPEC-29](./2026-07-26-SPEC-29-session-lifecycle-resume-list-delete.md) | Adapter-native session lifecycle: resume (ACP `session/load`\|`session/resume`, codex `thread/resume`), list, delete, fork — fixes server-restart resume for pi **and** codex | SPEC-27, SPEC-17, SPEC-19 |
| [SPEC-34](./2026-08-01-SPEC-34-message-navigator.md) ([plan](./2026-08-01-SPEC-34-PLAN.md)) | **Message navigator**: find your own messages in a long transcript. Two affordances: the desktop **cosy ripple rail** (switchable off, three options in Settings › Agents & Chat) and the mobile **messages sheet**. Markers are placed by **item index**, never scroll offset, because SPEC-21's reversed lazy list has no offset for un-built rows | SPEC-21, SPEC-24 |
| [SPEC-32](./2026-07-31-SPEC-32-github-gateway-and-budget.md) ([plan](./2026-07-31-SPEC-32-PLAN.md)) | **Centralised GitHub gateway + API budget indicator**: one door for every GitHub read (cache, dedupe, concurrency, spend accounting), cost-aware REST/GraphQL routing, a degradation ladder with an interactive reserve, and the sidebar-footer quota popover. Fixes PR pills vanishing under rate limits via a three-way `PrLookup` (`pr` / `none` / `unknown`) | SPEC-23, SPEC-19, SPEC-11 |
| [SPEC-40](./2026-08-06-SPEC-40-composer-footer-space.md) ([plan](./2026-08-06-SPEC-40-PLAN.md)) | **Composer footer: space by need** — the config pill was starved, not crowded: every `footerActions` entry got an equal-share `Flexible`, so SPEC-37's 36 pt usage ring reserved half the row and `FlexFit.loose` never redistributed the rest (pi's model label got 65.5 pt of the 187.5 pt it wanted; a four-option shape threw `RenderFlex`). Adds an intrinsic `Composer.footerTrailing` slot, drops the `provider/` prefix `pi-acp` prepends (full name to the tooltip, which had hard-coded the literal "Model"), and lets read-only chips yield to the model name — the last of those was a non-goal until codex measured at 49 % of its own name. Corrects SPEC-37's crowding premise | SPEC-26, SPEC-31, SPEC-37 |
| [SPEC-39](./2026-08-04-SPEC-39-queue-tray-and-promote.md) | **Queue tray + promote** — mockup variant C, the compact work-list presentation of the pending queue, as the second value of the same preference (`pinned` · `tray`) — the `inline`/in-transcript placement was removed, taking the trailer-row coupling with it. The bubbles are hollow and their controls one tight group. Adds `queue.promote`: interrupt the running turn so ONE queued message is delivered next, keeping the rest — composed from `reorderQueue` + `adapter.cancel()`, deliberately NOT from `cancel`, which clears the queue. A stale promote acks and does nothing, because aborting a turn on a late tap destroys work. Also renames the queue commands' message id to `queuedId`: as `id` it was silently overwriting the envelope's request id | SPEC-35, SPEC-38 |
| [SPEC-38](./2026-08-02-SPEC-38-pending-queue-edit-reorder.md) ([plan](./2026-08-02-SPEC-38-PLAN.md)) | **Pending queue: editable, reorderable, two placements** — a queued mid-turn message becomes a draft you can work on: edit in place (with the slash palette, agent commands only, because client commands act on the app *now*), reorder with ↑↓, cancel. Renders as ghost bubbles above the composer (SPEC-39 removed the in-transcript placement) | SPEC-35, SPEC-21, SPEC-34 |
| [SPEC-37 *(context usage)*](./2026-08-05-SPEC-37-context-usage.md) ([plan](./2026-08-05-SPEC-37-context-usage-PLAN.md)) | **Context usage: tokens vs limit, per session** — a composer-footer ring that opens a details panel (occupancy + cumulative billing breakdown + cost), unified across three sources that each report a different subset: codex `thread/tokenUsage/updated` (breakdown, no cost), ACP `usage_update` (aggregates only), and pi via the `makit-pi-usage` extension over the loopback bridge, because **pi-acp emits no `usage_update` at all**. Occupancy and billing are separate fields so nothing can draw them against the same bar (codex's cumulative total hit 39k while the context held 19.5k). Amended 2026-08-06: pi's totals are **derived** from its session entries every `turn_end`, so a resumed or compacted session reports correctly, and the extension moved to its own repo | SPEC-26, SPEC-32, SPEC-36 |
| [SPEC-37](./2026-08-03-SPEC-37-performance-metrics-dashboard.md) ([plan](./2026-08-03-SPEC-37-PLAN.md)) | **Performance dashboard**: make the memory/CPU efficiency claim checkable in-product — a sidebar-footer pulse popover (app / server / per-agent, with parked agents at `0.0%`) plus an in-window dashboard overlay (stacked CPU, RSS, frame p95, event-loop p99, wire, process table with `CPU-s`). Correct CPU semantics (`Δcpu ÷ Δwall`, never `ps %cpu`), whole-tree attribution with a churn-proof CPU ledger, one `ps` per tick, in-memory rings only (**never** the append-only event log), and the panel reports its own cost | SPEC-32, SPEC-19, SPEC-29, SPEC-13 |
| [SPEC-35](./2026-08-02-SPEC-35-mid-turn-steering-and-queue.md) ([plan](./2026-08-02-SPEC-35-PLAN.md)) | **Mid-turn messages: steer vs queue** — a message typed while the agent is working is steered into the running turn where the agent has a primitive for it (codex `turn/steer`) and queued-until-idle everywhere else (ACP has none, in v1 or the v2 draft). Adds `SessionDTO.queued` + `queue.cancel` and cancellable pending chips above the composer. Grounded in a live spike: a mid-turn codex `turn/start` is coerced into a steer and returns a **phantom** turn id (fixed by `87b4941`), while pi-acp queues internally and leaks the notice as agent prose | SPEC-27, SPEC-29, SPEC-33 |
| [SPEC-38](./2026-08-06-SPEC-38-pr-actions-next-step-bar.md) ([plan](./2026-08-06-SPEC-38-PLAN.md)) | **PR actions — the next-step bar**: replaces SPEC-23's two-zone composer bar with one derivation (`prStatus`) feeding all three PR surfaces; the bar states the loudest fact plus a `+n more` disclosure and one lifecycle CTA. Two action registers (tonal "ask the agent" prompts vs filled "do now" server commands), and the endings a PR never had — **Wrap up** (remove worktree · delete branch · fast-forward the PR's own `baseRefName`), **Discard**, **Squash & merge**, plus **Mark ready**, **Update branch** and a magic **Fix** that hands the agent every outstanding problem at once | SPEC-23, SPEC-32, SPEC-11, SPEC-19 |
| [SPEC-33](./2026-08-01-SPEC-33-user-attachments.md) ([plan](./2026-08-01-SPEC-33-PLAN.md)) | **User attachments** (phase 1 **done**): send images from the picker, camera, or clipboard paste (`super_clipboard`) — `POST /media` upload onto SPEC-22's content-addressed store, `send.message attachments[]`, delivered as a git-excluded file in the session worktree referenced by path (inline ACP image blocks deferred to a follow-up phase) | SPEC-22, SPEC-26, SPEC-29 |
| [SPEC-45](./2026-08-07-SPEC-45-starter-pane-parity.md) | **The starter pane keeps its work**: three capabilities "Choose a harness" lacked because it is not the composer the live pane is — the typed first message, the chosen harness and its model/reasoning picks are all destroyed by the tab switch that recreates the pane (it never used `composerDraftsProvider`, whose key space already reserved `starter:<worktreePath>` for "a session that hasn't started yet"), the slash palette shows no skills or prompts (agent commands only ever arrive on a live session's `session.commands`, so they are cached per harness+project from what one advertised), and the paperclip is inert (the live-pane guard asks whether a session exists, which is meaningless before one does — `POST /media` needs none). A follow-up phase moves the palette into the server's capability cache, keyed `agentId + fingerprint + cwd` | SPEC-27, SPEC-30, SPEC-33, SPEC-31 |

> **Note on the two SPEC-37s.** `2026-08-03-SPEC-37-performance-metrics-dashboard.md` and
> `2026-08-05-SPEC-37-context-usage.md` were numbered independently and collide. Both shipped
> under that number and are referenced by that number in commits, code comments and CI job
> names, so neither has been renumbered; they are distinguished by date and title.

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
