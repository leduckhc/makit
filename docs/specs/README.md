# makit — Specs (Daemon, CLI, Desktop App, Multiplexer Sessions)

These specs capture a brainstorming consensus (2026-07) to evolve makit from a
clunky foreground CLI into a **background service** with two first-class control
surfaces (a power-user CLI and a macOS desktop app), and to make phone-initiated
sessions spawn as **attachable background panes** in the user's terminal
multiplexer.

Each spec is written to be handed to a **separate agent**. They share contracts
but are otherwise independently implementable. Respect the dependency order.

## Spec naming

A spec file is named for **when it was created**, plus what it is about:

```text
docs/specs/<YYYYMMDD>-<HHMMSS>-SPEC-<slug>.md
docs/specs/20260807-004600-SPEC-cli-as-client.md
```

A sibling document keeps its parent's timestamp and slug, and adds a suffix:
`-PLAN`, `-REVIEW`, or `-ARCHITECTURE-AND-PLAN`.

Create one with the script. Do not hand-write the timestamp:

```sh
scripts/new-spec.sh "cli as client"          # a new spec
scripts/new-spec.sh --plan cli-as-client     # its plan, sharing the parent's stamp
```

**Refer to a spec by its slug**, in prose, in commit messages and in code comments:
`SPEC-cli-as-client`. The slug is the readable id. The timestamp only sorts the
directory and keeps the name unique.

### Why not numbers

Spec ids were sequential until 2026-08-18. A number had to be **claimed**, and
nothing in the repo did the claiming. Two branches in two worktrees could not see
each other, so they took the same number. That happened six times:

| number | first feature | second feature |
|---|---|---|
| 07 | background-wake-notifications | notifications-async-loop |
| 37 | performance-metrics-dashboard | context-usage |
| 38 | pending-queue-edit-reorder | pr-actions-next-step-bar |
| 46 | cli-as-client | doc-preview |
| 48 | status-and-activity | per-repo-settings |
| 51 | target-branch | preview-groups |

Both specs then shipped, and both were cited by that one number in code. So one
comment could name two unrelated features, and only its surrounding paragraph
said which. `SPEC-target-branch` recorded the cost in its own header: three
numbers were taken while its branch was in flight.

A timestamp needs no allocation. Two worktrees cannot collide on one, because
neither has to ask.

### What enforces this

`app/test/spec_naming_test.dart`. It fails when a filename breaks the pattern,
when two specs claim one slug or one timestamp, when a numeric spec id appears
anywhere, or when any `SPEC-<slug>` reference points at a spec that does not
exist. A renamed spec therefore breaks a test, not a reader.

### The 2026-08-18 migration

84 files were renamed and 2893 references were rewritten. Legacy timestamps are
reconstructed, not measured: the date is the one the old filename carried, and
the time encodes the retired number (`001500` was 15). Git's own commit time was
rejected for the job — batch commits gave six specs one identical stamp, and
merge order inverted the sequence. `scripts/rewrite_spec_refs.py` holds the
resolution rules, and `scripts/spec-migration/map.json` records every old name
beside its new one. Those two files keep the retired numbers on purpose, so the
naming test exempts them.

---

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
| [SPEC-daemon-control-plane](./20260705-000100-SPEC-daemon-control-plane.md) | makit daemon & local control plane | — (foundation) |
| [SPEC-cli-client-subcommands](./20260705-000200-SPEC-cli-client-subcommands.md) | CLI client subcommands | SPEC-daemon-control-plane |
| [SPEC-desktop-control-app](./20260705-000300-SPEC-desktop-control-app.md) | macOS desktop **control** app (Flutter reuse; done — Phase 1 via PR #11, Phase 4 via PR #16) | SPEC-daemon-control-plane |
| [SPEC-multiplexer-adapter-layer](./20260705-000400-SPEC-multiplexer-adapter-layer.md) | Multiplexer adapter layer + herdr | — (foundation) |
| [SPEC-session-in-pane-spawning](./20260705-000500-SPEC-session-in-pane-spawning.md) | Session-in-pane spawning + lifecycle | **Retired — superseded by SPEC-new-session-config-at-spawn** (pi-over-ACP, headless) |
| [SPEC-composer-adaptive-input](./20260707-000600-SPEC-composer-adaptive-input.md) | Composer: adaptive input bar + send-on-content | — |
| [SPEC-actionable-notifications](./20260708-000800-SPEC-actionable-notifications.md) | Slice 1: actionable notifications (approve/reply from lock screen) | **Done** |
| [SPEC-background-wake-notifications](./20260708-000700-SPEC-background-wake-notifications.md) | Slice 2: background wake for notifications (force-quit push) | **Done** (requires `push.json`; see [PUSH.md](../PUSH.md)) |
| [SPEC-desktop-chat-app](./20260712-001000-SPEC-desktop-chat-app.md) | makit **desktop chat app** (chat-first macOS client; multi-harness; git/PR roadmap) | SPEC-daemon-control-plane, SPEC-desktop-control-app, mobile chat stack |
| [SPEC-repo-centric-home](./20260712-001100-SPEC-repo-centric-home.md) | Repo-centric mobile home (worktrees, diff stats, PRs) | SPEC-session-in-pane-spawning, SPEC-composer-adaptive-input |
| [SPEC-worktree-scoped-panes](./20260717-002000-SPEC-worktree-scoped-panes.md) | Worktree-scoped pane layouts | **Superseded by SPEC-desktop-workspace-tabs**; its keyed-layout *mechanism* is rehabilitated by SPEC-tab-groups (keyed by group, not worktree) |
| [SPEC-acp-config-options-unified-composer](./20260724-002600-SPEC-acp-config-options-unified-composer.md) | ACP `configOptions` + unified composer config model (build first) | SPEC-server-adapter-consolidation |
| [SPEC-new-session-config-at-spawn](./20260724-002700-SPEC-new-session-config-at-spawn.md) | New-session config at spawn (worktree · harness · config options; desktop dialog + mobile sheet; **cached capability catalog**; native pi/mux-pane removed — pi over `pi-acp`, codex over `app-server`, projected into one config model) | SPEC-acp-config-options-unified-composer, SPEC-desktop-chat-app |
| [SPEC-desktop-workspace-tabs](./20260724-002800-SPEC-desktop-workspace-tabs.md) | Desktop/iPad workspace: recursive splits + tabs (supersedes SPEC-worktree-scoped-panes) — **decisions 3 & 6 amended by SPEC-tab-groups** | SPEC-desktop-chat-app, SPEC-decomposition-and-dedup, SPEC-new-session-config-at-spawn |
| [SPEC-tab-groups](./20260729-003000-SPEC-tab-groups.md) ([plan](./20260729-003000-SPEC-tab-groups-PLAN.md)) | **Tab groups**: worktree groups (derived membership) + boards (curated, cross-repo); per-group layouts, three closes, recently closed boards (amends SPEC-desktop-workspace-tabs decisions 3 & 6) | SPEC-desktop-workspace-tabs, SPEC-new-session-config-at-spawn, SPEC-session-lifecycle-resume-list-delete |
| [SPEC-session-lifecycle-resume-list-delete](./20260726-002900-SPEC-session-lifecycle-resume-list-delete.md) | Adapter-native session lifecycle: resume (ACP `session/load`\|`session/resume`, codex `thread/resume`), list, delete, fork — fixes server-restart resume for pi **and** codex | SPEC-new-session-config-at-spawn, SPEC-server-hotpath-and-state, SPEC-decomposition-and-dedup |
| [SPEC-message-navigator](./20260801-003400-SPEC-message-navigator.md) ([plan](./20260801-003400-SPEC-message-navigator-PLAN.md)) | **Message navigator**: find your own messages in a long transcript. Two affordances: the desktop **cosy ripple rail** (switchable off, three options in Settings › Agents & Chat) and the mobile **messages sheet**. Markers are placed by **item index**, never scroll offset, because SPEC-chat-scroll-anchoring's reversed lazy list has no offset for un-built rows | SPEC-chat-scroll-anchoring, SPEC-inline-expandable-tool-rows |
| [SPEC-github-gateway-and-budget](./20260731-003200-SPEC-github-gateway-and-budget.md) ([plan](./20260731-003200-SPEC-github-gateway-and-budget-PLAN.md)) | **Centralised GitHub gateway + API budget indicator**: one door for every GitHub read (cache, dedupe, concurrency, spend accounting), cost-aware REST/GraphQL routing, a degradation ladder with an interactive reserve, and the sidebar-footer quota popover. Fixes PR pills vanishing under rate limits via a three-way `PrLookup` (`pr` / `none` / `unknown`) | SPEC-pr-status-and-actions, SPEC-decomposition-and-dedup, SPEC-repo-centric-home |
| [SPEC-composer-footer-space](./20260806-004000-SPEC-composer-footer-space.md) ([plan](./20260806-004000-SPEC-composer-footer-space-PLAN.md)) | **Composer footer: space by need** — the config pill was starved, not crowded: every `footerActions` entry got an equal-share `Flexible`, so SPEC-context-usage's 36 pt usage ring reserved half the row and `FlexFit.loose` never redistributed the rest (pi's model label got 65.5 pt of the 187.5 pt it wanted; a four-option shape threw `RenderFlex`). Adds an intrinsic `Composer.footerTrailing` slot, drops the `provider/` prefix `pi-acp` prepends (full name to the tooltip, which had hard-coded the literal "Model"), and lets read-only chips yield to the model name — the last of those was a non-goal until codex measured at 49 % of its own name. Corrects SPEC-context-usage's crowding premise | SPEC-acp-config-options-unified-composer, SPEC-model-picker-menu-per-model-config, SPEC-context-usage |
| [SPEC-queue-tray-and-promote](./20260804-003900-SPEC-queue-tray-and-promote.md) | **Queue tray + promote** — mockup variant C, the compact work-list presentation of the pending queue, as the second value of the same preference (`pinned` · `tray`) — the `inline`/in-transcript placement was removed, taking the trailer-row coupling with it. The bubbles are hollow and their controls one tight group. Adds `queue.promote`: interrupt the running turn so ONE queued message is delivered next, keeping the rest — composed from `reorderQueue` + `adapter.cancel()`, deliberately NOT from `cancel`, which clears the queue. A stale promote acks and does nothing, because aborting a turn on a late tap destroys work. Also renames the queue commands' message id to `queuedId`: as `id` it was silently overwriting the envelope's request id | SPEC-mid-turn-steering-and-queue, SPEC-pending-queue-edit-reorder |
| [SPEC-pending-queue-edit-reorder](./20260802-003800-SPEC-pending-queue-edit-reorder.md) ([plan](./20260802-003800-SPEC-pending-queue-edit-reorder-PLAN.md)) | **Pending queue: editable, reorderable, two placements** — a queued mid-turn message becomes a draft you can work on: edit in place (with the slash palette, agent commands only, because client commands act on the app *now*), reorder with ↑↓, cancel. Renders as ghost bubbles above the composer (SPEC-queue-tray-and-promote removed the in-transcript placement) | SPEC-mid-turn-steering-and-queue, SPEC-chat-scroll-anchoring, SPEC-message-navigator |
| [SPEC-context-usage *(context usage)*](./20260805-003700-SPEC-context-usage.md) ([plan](./20260805-003700-SPEC-context-usage-PLAN.md)) | **Context usage: tokens vs limit, per session** — a composer-footer ring that opens a details panel (occupancy + cumulative billing breakdown + cost), unified across three sources that each report a different subset: codex `thread/tokenUsage/updated` (breakdown, no cost), ACP `usage_update` (aggregates only), and pi via the `makit-pi-usage` extension over the loopback bridge, because **pi-acp emits no `usage_update` at all**. Occupancy and billing are separate fields so nothing can draw them against the same bar (codex's cumulative total hit 39k while the context held 19.5k). Amended 2026-08-06: pi's totals are **derived** from its session entries every `turn_end`, so a resumed or compacted session reports correctly, and the extension moved to its own repo | SPEC-acp-config-options-unified-composer, SPEC-github-gateway-and-budget, SPEC-computer-use |
| [SPEC-performance-metrics-dashboard](./20260803-003700-SPEC-performance-metrics-dashboard.md) ([plan](./20260803-003700-SPEC-performance-metrics-dashboard-PLAN.md)) | **Performance dashboard**: make the memory/CPU efficiency claim checkable in-product — a sidebar-footer pulse popover (app / server / per-agent, with parked agents at `0.0%`) plus an in-window dashboard overlay (stacked CPU, RSS, frame p95, event-loop p99, wire, process table with `CPU-s`). Correct CPU semantics (`Δcpu ÷ Δwall`, never `ps %cpu`), whole-tree attribution with a churn-proof CPU ledger, one `ps` per tick, in-memory rings only (**never** the append-only event log), and the panel reports its own cost | SPEC-github-gateway-and-budget, SPEC-decomposition-and-dedup, SPEC-session-lifecycle-resume-list-delete, SPEC-desktop-settings-rework |
| [SPEC-mid-turn-steering-and-queue](./20260802-003500-SPEC-mid-turn-steering-and-queue.md) ([plan](./20260802-003500-SPEC-mid-turn-steering-and-queue-PLAN.md)) | **Mid-turn messages: steer vs queue** — a message typed while the agent is working is steered into the running turn where the agent has a primitive for it (codex `turn/steer`) and queued-until-idle everywhere else (ACP has none, in v1 or the v2 draft). Adds `SessionDTO.queued` + `queue.cancel` and cancellable pending chips above the composer. Grounded in a live spike: a mid-turn codex `turn/start` is coerced into a steer and returns a **phantom** turn id (fixed by `87b4941`), while pi-acp queues internally and leaks the notice as agent prose | SPEC-new-session-config-at-spawn, SPEC-session-lifecycle-resume-list-delete, SPEC-user-attachments |
| [SPEC-pr-actions-next-step-bar](./20260806-003800-SPEC-pr-actions-next-step-bar.md) ([plan](./20260806-003800-SPEC-pr-actions-next-step-bar-PLAN.md)) | **PR actions — the next-step bar**: replaces SPEC-pr-status-and-actions's two-zone composer bar with one derivation (`prStatus`) feeding all three PR surfaces; the bar states the loudest fact plus a `+n more` disclosure and one lifecycle CTA. Two action registers (tonal "ask the agent" prompts vs filled "do now" server commands), and the endings a PR never had — **Wrap up** (remove worktree · delete branch · fast-forward the PR's own `baseRefName`), **Discard**, **Squash & merge**, plus **Mark ready**, **Update branch** and a magic **Fix** that hands the agent every outstanding problem at once | SPEC-pr-status-and-actions, SPEC-github-gateway-and-budget, SPEC-repo-centric-home, SPEC-decomposition-and-dedup |
| [SPEC-user-attachments](./20260801-003300-SPEC-user-attachments.md) ([plan](./20260801-003300-SPEC-user-attachments-PLAN.md)) | **User attachments** (phase 1 **done**): send images from the picker, camera, or clipboard paste (`super_clipboard`) — `POST /media` upload onto SPEC-assistant-display-media's content-addressed store, `send.message attachments[]`, delivered as a git-excluded file in the session worktree referenced by path (inline ACP image blocks deferred to a follow-up phase) | SPEC-assistant-display-media, SPEC-acp-config-options-unified-composer, SPEC-session-lifecycle-resume-list-delete |
| [SPEC-cli-as-client](./20260807-004600-SPEC-cli-as-client.md) ([plan](./20260807-004600-SPEC-cli-as-client-PLAN.md)) | **The CLI is a client**: session lifecycle from the terminal (`ls`/`new`/`send`/`tail`/`wait`/`resume`/`rm`) and **handoff as a command** — a structured manifest rendered into a fresh session's first message, cross-harness, with `parentId` lineage on the wire. One transport (WSS; the frozen control socket stays lifecycle-only), the CLI gets **its own capability-scoped device** instead of borrowing `devices.json[0]`'s phone bearer, and `startOpts()` injects `MAKIT_SESSION_ID`/`MAKIT_CLI_TOKEN` so **an agent can drive makit from inside its own session** — bounded by a server-side spawn-depth/fan-out guard. `--json` is the wire NDJSON verbatim (no second projection) and exit codes carry `SessionStatus`. Completes SPEC-session-lifecycle-resume-list-delete's pending `session.fork` in P2. **Rev 2** after dual codex review: lineage is derived from the credential (a wire `parentId` made the spawn guard forgeable), the stranded-prompt audience is enforced on the *pending record* and the *answer* too (`replayPendingTo` re-sent every prompt to every newly-authed client, and the first `srv.response` won with no sender check), `wait` is edge-triggered (`send.message` acks before promotion, so a composed `new + send + wait` exited 0 having waited for nothing), exit `20` keys off `session.error` because **nothing emits `status: "error"`**, `--carry` reads a bounded new `session.transcript` instead of flooding through `sub {fromSeq}`, and `caps` enforcement became a decision (D17) once the review showed four decisions resting on a principal the connection does not have | SPEC-cli-client-subcommands, SPEC-daemon-control-plane, SPEC-new-session-config-at-spawn, SPEC-session-lifecycle-resume-list-delete, SPEC-user-attachments |
| [SPEC-starter-pane-parity](./20260807-004500-SPEC-starter-pane-parity.md) | **The starter pane keeps its work**: three capabilities "Choose a harness" lacked because it is not the composer the live pane is — the typed first message, the chosen harness and its model/reasoning picks are all destroyed by the tab switch that recreates the pane (it never used `composerDraftsProvider`, whose key space already reserved a `starter:` prefix for "a session that hasn't started yet"), the slash palette shows no skills or prompts (agent commands only ever arrive on a live session's `session.commands`, so they are cached per harness+project from what one advertised), and the paperclip is inert (the live-pane guard asks whether a session exists, which is meaningless before one does — `POST /media` needs none). A follow-up phase moves the palette into the server's capability cache, keyed `agentId + fingerprint + cwd` | SPEC-new-session-config-at-spawn, SPEC-tab-groups, SPEC-user-attachments, SPEC-model-picker-menu-per-model-config |
| [SPEC-session-timings](./20260809-004700-SPEC-session-timings.md) | **How long did that take**: durations for the four scopes that currently have none — a finished tool row shows its elapsed only past 2 s (below that the label is noise on the one line that already ellipsizes; the exact figure is unconditional in the expanded body), a *running* one gains a live counter beside its spinner that takes `kStatusWarning` past a minute (today a 200 ms call and an 18-minute hang render identically), thinking reads `Thought for 12s` because a collapsed reasoning row has no other structured fact, the `WorkingIndicator` counts while a turn runs and a dim receipt (`2m 13s · 14 tools`, plus a `waiting on you` token only when a gate blocked) closes it, and the session rollup lands in the existing usage popover. Almost entirely a *derivation*: every event already carries `ts` and `session.status` is already logged, so only `SessionDTO.createdAt` touches the wire | SPEC-decomposition-and-dedup, SPEC-mid-turn-steering-and-queue, SPEC-context-usage, SPEC-chat-scroll-anchoring |

> **Note on the two dashboards.** `20260803-003700-SPEC-performance-metrics-dashboard.md` and
> `20260805-003700-SPEC-context-usage.md` were drafted independently and collided on one number
> under the retired numeric scheme. They now carry their own slugs, so nothing distinguishes them
> by date and title any more. See [Spec naming](#spec-naming).

```text
SPEC-daemon-control-plane ─┬─> SPEC-cli-client-subcommands (CLI clients)
         └─> SPEC-desktop-control-app (desktop app)
SPEC-multiplexer-adapter-layer ───> SPEC-session-in-pane-spawning (spawn pi in pane — RETIRED by SPEC-new-session-config-at-spawn)

# Current workspace/config wave (build in order):
SPEC-acp-config-options-unified-composer (ACP configOptions) ──> SPEC-new-session-config-at-spawn (new-session config) ──> SPEC-desktop-workspace-tabs (workspace tabs)
                                                             └──> SPEC-tab-groups (tab groups)
```

SPEC-daemon-control-plane and SPEC-multiplexer-adapter-layer can start in parallel. SPEC-cli-client-subcommands/03 need SPEC-daemon-control-plane's control
contract frozen. SPEC-acp-config-options-unified-composer → SPEC-new-session-config-at-spawn → SPEC-desktop-workspace-tabs is the required build order for the
current wave (each depends on the prior). SPEC-session-in-pane-spawning is retired (pi is now headless
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
