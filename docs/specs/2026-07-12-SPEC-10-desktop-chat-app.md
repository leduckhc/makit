# SPEC-10 — makit desktop chat app

**Status:** draft · **Depends on:** SPEC-01 (control plane), SPEC-03 (desktop control app), the mobile chat stack (`app/lib/{transport,store,ui}`) · **Blocks:** —

## Goal

Turn the macOS app from a **server operator's control panel** (SPEC-03) into a
**chat-first desktop client** — a sleek, modern chat UI (Claude Desktop / Codex
Desktop caliber) for driving coding agents locally. It runs **multiple harnesses**
(`pi`, `codex`, `claude`, and later `opencode`, `cline`, …), works naturally with
**git / GitHub / GitLab**, and has built-in **pull-request workflows** (create,
comment, close). The existing control screens (Devices / QR / Status) are demoted
to a **Settings & Server** section.

This spec supersedes the "Chatting from the desktop is explicitly deferred to a
future version" note in SPEC-03.

## Why

SPEC-03 made the macOS build a control app because reusing the mobile app booted
it into the phone's pairing/chat flow, which was the wrong role for a *server
operator*. But the day-to-day value is chatting with agents **on the desktop**,
where the code and the daemon already live. The phone stays a companion; the
desktop becomes the primary cockpit.

We keep the SPEC-03 investment (control socket client, daemon lifecycle, tray,
device/QR/status screens) and the mobile chat stack (transport, store, session
UI, composer, design system) — this is an **extension, not a rewrite**.

## Decisions (consensus — source of truth for this spec)

1. **Tech = extend the existing Flutter desktop app.** Not Electron/Tauri/native.
   Reuse the server, transport, pairing, tray/daemon glue, and the locked design
   system (`design-system/makit/MASTER.md`). We own the polish.
2. **Chat is the main window.** The app launches into a two-pane chat surface.
   The SPEC-03 control screens (Devices / QR / Status / Sessions) move behind a
   **Settings & Server** section, still reachable from the window and the tray.
3. **Window shape = desktop two-pane** (persistent session sidebar on the left,
   chat pane on the right) — not the mobile push-navigation flow. The chat pane
   reuses the mobile chat item widgets and composer so behavior stays identical.
4. **Connection = self-pair over the local control socket.** The desktop is
   trusted-local and already owns the daemon. Rather than add a server "loopback
   no-auth" mode, it mints a normal pair token via the control socket
   (`pair.mint` + `status`) and completes the same `hello { pair }` handshake
   every phone uses — but against the **loopback** WS listener
   (`wss://127.0.0.1:<port>`, whose TLS cert SAN already lists `127.0.0.1`). No
   QR scan; no new server auth path. Subsequent launches reconnect from the
   persisted bearer.
5. **Harness registry is extensible, not hardcoded.** The picker is driven by the
   server's `agents.list` (`AgentDescriptor { id, label, transport, available }`).
   v1 ships whatever the host can spawn today; `opencode` / `cline` become new
   server adapters behind the same interface later.
6. **Git / GitHub / GitLab / PR ops live server-side** (recommended default),
   exposed as new protocol commands. The server owns the project `cwd`, runs on
   the host, and can shell out to `git` + `gh`/`glab` (or REST). Bonus: mobile
   inherits these later for free. *(Phases 4–5; contract not frozen in this spec.)*
7. **v1 excludes code navigation, an embedded terminal, and a browser.** Better
   dedicated tools exist for those; makit desktop is a chat cockpit.

## Phasing

This spec's **v1 milestone is Phase 1** (the chat spine). Phases 2–5 are the
roadmap — each needs its own frozen contract before implementation (especially
the git/PR protocol in 4–5).

| Phase | Outcome | State |
|------|---------|-------|
| **1** | Desktop chat surface — two-pane shell, self-pair over loopback, one harness end-to-end (send → stream → tool/diff cards) | **this spec's v1** |
| 2 | Harness picker + per-session config (model, approval policy) surfaced in the header | roadmap |
| 3 | Settings & Configuration — harness binaries/paths, git identity, GitHub/GitLab hosts + tokens, appearance, notifications | roadmap |
| 4 | Git integration — repo/branch status, diff view, stage/commit in session context (server-side git commands) | roadmap |
| 5 | PR workflows — create / comment / close PRs against GitHub + GitLab from a session | roadmap |

## Architecture

```
Flutter desktop app  ──loopback WSS──▶  makit daemon (Node/TS)  ──▶  harness adapters (pi/codex/claude/…)
  two-pane chat + settings              session mgr, event log        git + GitHub/GitLab + PR ops (P4–5)
        │                                        ▲
        └──── unix control socket ───────────────┘  (daemon lifecycle, pair.mint, status)
```

- The chat client and daemon run on the **same host**; the client connects over
  loopback WSS as a normal paired device (Decision 4).
- The chat surface is entirely **provider-driven** off the existing store
  (`projectsProvider`, `sessionsProvider`, `chatItemsProvider`,
  `storeControllerProvider`), fed by the connection/transport — so it reuses the
  tested mobile chat engine without change.

## Scope

### In (Phase 1 / v1)
- **App launches into a two-pane chat window** (`DesktopChatShell`): a fixed-width
  session sidebar + a chat pane. Replaces the control dashboard as `home`.
- **Loopback self-pairing** on launch: ensure the daemon is running, then
  `pair.mint` + `status` → `PairInfo(127.0.0.1, port, fingerprint, token)` →
  `ConnectionController.pairWith`. Idempotent (no-op when a bearer already
  exists). Best-effort: on failure the window shows its empty state.
- **Sidebar**: projects → their sessions, a **New session** action, connection
  status, and an entry point to **Settings & Server**. Selecting a session sets
  the current session (app state, not a route).
- **Chat pane**: transcript (user bubbles, agent messages, thinking, tool-call /
  diff cards) + a docked composer, reusing `ChatBubble` / `AgentMessage` /
  `ToolCallCard` / `Composer` / `handleClientCommand`. Auto-scrolls to newest;
  shows a working indicator while the agent runs.
- **New-session flow**: pick a project (or add one via the folder browser) + a
  harness (from `agents.list`, unavailable ones disabled) → `spawnSession` →
  select the new session.
- **Settings & Server**: the SPEC-03 control screens (Devices / QR / Status /
  Sessions) reachable as a pushed page — no functionality lost.
- **Larger default window** sized for a two-pane layout.

### Out (v1)
- Phases 2–5 (harness config surfacing, full settings, git, PR workflows).
- Code navigation, embedded terminal, browser (Decision 7).
- Windows/Linux desktop — macOS only (matches SPEC-03).
- Any new **server** auth mode — Decision 4 reuses existing pairing.
- Multi-user / team mode.

## Design notes / contracts consumed
- **Control plane** (SPEC-01) over `~/.makit/control.sock`: verbs `status`
  (→ `port`, `fingerprint`), `pair.mint` (→ pair token), daemon `start/stop`.
- **Chat protocol** (existing WS + JSON): `session.spawn`, `agents.list`,
  `send.message`, session events, `srv.request`/`srv.response` — all already
  spoken by `app/lib/{transport,store}`.
- **Design system**: `design-system/makit/MASTER.md` (grey neutrals + green
  accent, chat bubbles, tool cards, composer). Desktop reuses tokens/widgets.
- **Keep the mobile app unaffected**: desktop chat lives in `app/lib/desktop/`;
  reuses `store`/`transport`/`ui` widgets read-only. Gate behind `Platform.isMacOS`
  (the existing `main.dart` branch).

## Acceptance criteria (Phase 1 / v1)
- [ ] macOS build launches into the **two-pane chat window**, not the control
      dashboard; Devices/QR/Status remain reachable via **Settings & Server**.
- [ ] On launch the app brings the daemon up (if needed) and **self-pairs over
      loopback** with no QR scan; a second launch reconnects from the persisted
      bearer without re-pairing.
- [ ] The sidebar lists real projects/sessions; selecting one shows its
      transcript in the chat pane.
- [ ] **New session** lets the user choose a project + a harness from
      `agents.list` and spawns it; the new session becomes selected.
- [ ] A message sent from the composer **round-trips end-to-end** against a real
      harness (e.g. `pi`): user message → streamed agent reply → tool/diff cards
      render.
- [ ] Mobile build unaffected; `flutter analyze --fatal-infos` clean; `flutter
      test` green (including new desktop tests); `app/tool/audit.sh` passes.

## Open questions
- **Git/PR placement (Phases 4–5):** server-side (recommended — owns `cwd`,
  reusable by mobile) vs. client-side. Freeze in a follow-up spec before P4.
- **GitHub/GitLab access:** shell out to `gh`/`glab` vs. REST with stored tokens;
  where credentials live (Settings, P3).
- **Tray behavior with chat as home:** should "Open dashboard" open chat and the
  QR menu deep-link into Settings & Server? (v1 keeps the tray minimal.)
- **Settings & Server presentation:** pushed page (v1) vs. a dedicated settings
  window (P3, aligns with README milestone M4).
- **Two-pane polish:** desktop-native folder picker vs. reusing the mobile modal
  folder browser; sidebar resizing/persistence.
