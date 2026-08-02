# makit — UX Specification

> Mobile-first coding agent client. A personal server runs on your desktop (or any
> always-on box) and exposes your agent CLI sessions (codex, pi, claude, etc.) to
> a phone / tablet / web client over a paired, end-to-end-authenticated channel.

## Product principles

1. **Phone is a first-class co-client**, not a remote viewer. Typing on the phone
   is mirrored live into the desktop session. The desktop tmux pane stays
   canonical, but the phone sees the same stream and can drive it.
2. **Chat UI, not a terminal.** Render agent output as chat bubbles with
   collapsible tool cards. Drill into diffs/files fullscreen. Preserve terminal
   power-user affordances (slash commands, @-mentions, keyboard shortcuts) but
   not terminal *aesthetics*.
3. **Personal now, team-ready later.** Single-user server, multi-device. Data
   model carries `user_id` / ACL hooks so multi-user is a non-breaking addition.
4. **Agent-agnostic.** The server wraps any agent CLI (codex, pi, claude-code,
   aider, …) via a thin adapter; the phone speaks one protocol.

---

## 1. Pairing & transport

| Layer        | Choice                                                                                  |
| ------------ | --------------------------------------------------------------------------------------- |
| Primary pair | **QR code** shown by desktop server, scanned by phone (WhatsApp-Web style)              |
| LAN          | **mDNS / Bonjour** auto-discovery on same Wi-Fi                                         |
| Remote       | **Overlay VPN** (Tailscale-style) — no public ingress, NAT traversal handled by overlay |
| Crypto       | Each paired device gets a long-lived keypair; server stores known device pubkeys        |
| Revocation   | Server UI lists paired devices; user can revoke individually                            |

Bootstrap flow:

1. User installs server (`brew install makit` / `makit serve`).
2. `makit serve` prints a QR + short pairing code in the terminal.
3. Phone app: "Pair device" → scan QR → handshake → device keypair stored.
4. Subsequent launches: app auto-finds server via mDNS on LAN, or via overlay
   VPN when remote. No password, no relay account.

---

## 2. Information architecture

```
App
├── Projects                          (home, default tab)
│   └── Project (= repo / cwd)
│       └── Sessions
│           └── Session (chat view)
│               ├── Tool card → Fullscreen drilldown (diff / file / output)
│               └── Composer (slash, @, voice)
├── Devices & pairing
└── Settings
```

### Home: Projects → Sessions

- Top level lists **projects** the server knows about (auto-detected from
  recent cwd's of agent sessions; user can pin/hide).
- Each project shows: name, repo path, count of active sessions, last activity.
- Drill in: sessions belonging to that project, each annotated with:
  - Agent (codex / pi / claude / …)
  - Status: `idle` · `running` · `awaiting-input` · `awaiting-approval` · `error`
  - Last message preview + timestamp
- `+` on a project header → **Spawn new session**: pick agent CLI + initial
  prompt + (optional) branch.

---

### Desktop canvas: groups (SPEC-30)

The desktop window is a **sidebar** (the world) beside a **canvas** (one view
onto part of it). The sidebar — repos ▸ worktrees ▸ agents — never changes when
the canvas does.

What is on the canvas is owned by a **group**, and there are exactly two kinds,
differing only in *who decides membership*:

| | Worktree group | Board |
|---|---|---|
| Membership | **derived**: every agent on that branch, nothing else | **curated**: a hand-picked list, may span branches and repos |
| A new session there | joins automatically | only if you add it |
| Closing it | free — clicking the branch rebuilds it identically | goes to **Recently closed boards** (its list cannot be rebuilt) |

A group is a *view*, never a place: it cannot tell an agent where to run. That
single sentence decides the rest of the behaviour:

- **`+` differs by kind.** In a worktree group the branch already answers "where
  does it run?", so `+` starts an agent in place (harness cards + model/reasoning
  pills + composer). A board has no branch, so `+` opens the agent picker, whose
  *New session…* row goes through the New-session dialog and pins the result.
- **Sidebar clicks navigate, never mutate.** Clicking an agent takes you to a
  group that *already* holds it. Only an explicit add — drag, quick-pin, or a
  tick in the picker — can put a foreign agent into a worktree group, and doing
  so **converts that group into a board** rather than leaking into it.
- **Three distinct closes.** `✕` on a group tab closes the view only; `✕` on a
  pane archives the agent in a worktree group but merely **unpins** it on a
  board; deleting a worktree is the only thing that touches git.
- **Layout is yours.** The `Agents side by side` setting is a *placement policy*
  — it decides whether the next agent opens as a pane or a tab, and never
  re-arranges panes you positioned.
- The title strip carries the group tabs (scrolling, `⌘1`–`⌘9` for the first
  nine) on the left and the "Open in editor" split button, which always targets
  the **active pane's** worktree, on the right.

**Mobile is unaffected** — it keeps its repo → worktree list and its
new-session sheet.

---

## 3. Session view

**Layout:** chat + collapsible tool cards.

- User messages right, agent messages left.
- Tool calls render as **cards** with a 1-line summary (e.g. `edit src/foo.ts
  · +12 −3`). Collapsed by default. Tap → **fullscreen drilldown**:
  - Diff viewer (syntax-highlighted, swipe-back)
  - File viewer
  - Command output (monospace, copyable)
- Status chip pinned to top of session: agent state + which other devices are
  currently viewing this session.
- Long-press a message → copy, quote-reply, retry-from-here.

**Finding your own messages (SPEC-34).** A long session is ~90% agent output, so
re-reading your own prompts must not mean scrolling blind. One **message
navigator** renders over the transcript, chosen per surface:

| | Desktop | Mobile |
|---|---|---|
| How you get back | one of four transcript overlays (rail · palette · breadcrumb · outline) | **My messages** in the session-actions (`⋯`) menu → sheet, newest first, tap to jump |
| Configured by | picker + per-style options in Settings › Agents & Chat | nothing — no mobile navigator settings |

Each app root *overrides* the shared style provider with what that surface can
offer; mobile leaves it at `off`, so an unsuitable style is unreachable on a phone
by construction rather than by a coercion call someone must remember. The
styles are pointer designs — the rail and breadcrumb need hover — and a phone has
no screen to spend on permanent chrome, so mobile uses a sheet from the actions
menu instead. (An edge-drag scrubber was built for touch and removed: it asked a
thumb for precision it lacks, on the edge iOS reserves for swipe-back.)

After any jump the landing row briefly outlines itself (`JumpFlashHighlight`).
On mobile that is load-bearing: the sheet dismisses, so the outline is the only
thing showing where you arrived.

Navigators anchored at the top must clear the floating glass bar: the overlay
takes a `topInset` and pads once for all styles.

> **Do not place navigator markers proportionally to scroll position.** The
> transcript is a reversed lazy list, so rows that have not been laid out have no
> scroll offset, and deriving one means measuring the whole history — the lurch
> SPEC-21 removed. Markers are placed by message **order**; jumping is resolved by
> `SliverGeometry.scrollOffsetCorrection` *inside* layout, never from a post-frame
> callback (that paints the wrong frame first — a visible blink). This is the one
> constraint to re-read before touching any of it.

---

## 4. Composer affordances

| Affordance              | Behavior                                                                                       |
| ----------------------- | ---------------------------------------------------------------------------------------------- |
| `/` slash commands      | Fuzzy palette over server-defined + per-agent commands (e.g. `/approve`, `/cancel`, `/model`). |
| `@` mentions            | Reference files (`@src/foo.ts`), sessions, panes, branches; resolved server-side.              |
| 🎙 voice                | Hold-to-talk dictation, send-on-release. Transcription server-side (configurable).             |
| Quick-action chips      | When agent is awaiting input/approval, show contextual chips above keyboard.                   |
| Keyboard shortcuts      | Hardware-keyboard parity with desktop (⌘K palette, ⌘↩ send, etc.).                             |

---

## 5. Continuity model

- **Live mirroring**: keystrokes/messages on phone stream into the desktop
  session as if typed in the pane (not just final messages). Desktop tmux/agent
  UI reflects them in real time.
- **No single-active-remote lock**: phone + tablet + web can all observe and
  drive the same session simultaneously. Each device shows the others as
  presence indicators.
- Desktop pane remains **canonical** — server is source of truth for transcript
  and agent process lifecycle.

---

## 6. Approvals

Per-session policy, set at spawn time and changeable mid-session:

- `yolo` — agent runs autonomously; phone observes.
- `ask-on-risky` *(default)* — writes / shell / network / destructive ops
  require approval. Push notification + inline approve/deny chip.
- `ask-always` — every tool call requires explicit approval.

Approval prompts include: tool name, target (file/command), short preview, and
"approve once" vs "approve for this session" options.

---

## 7. Notifications (all on by default)

| Trigger              | Example                                              |
| -------------------- | ---------------------------------------------------- |
| Agent awaiting input | "codex@makit-repo is waiting on you"                  |
| Long task completed  | "Tests passed (42/42) in 2m13s" / "Build failed"     |
| Approval required    | "Approve: write to `~/.ssh/config`?"                 |
| Errors / anomalies   | Crash, stuck loop, repeated tool failure             |

Delivery: APNs / FCM via server → relay → device. Per-session and per-type
mute controls.

---

## 8. Offline behavior

- **Queue & sync**: messages composed offline are queued locally and flushed on
  reconnect, in order, with optimistic display.
- Transcript is **cached** locally per session for offline reading.
- The agent process keeps running on the server regardless of phone state — the
  phone never blocks agent execution.

---

## 9. Multi-device

- Same paired account = same view across phone, tablet, web.
- All devices see all sessions live.
- Presence: each session shows which other devices are currently open on it.
- No "active remote" lock; conflicts resolved by last-write-wins on the
  message stream (server timestamps).

---

## 10. Identity & scope

- **v1: personal.** One server = one human. Multiple paired devices.
- **Forward-compatible:** data model carries `user_id` and ACL hooks from day
  one so a future `team` mode is additive, not a rewrite.
- No mandatory cloud account. Optional hosted relay only for push
  notifications and NAT traversal fallback.

---

## Out of scope for v1

- Web client (design protocol so it's trivial to add, but ship native mobile first).
- Team / multi-user.
- On-device LLM drafting.
- External editor handoff (Working Copy / VS Code web integration).
