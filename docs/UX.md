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

### Ports: what a branch is serving (SPEC-41)

A worktree that has something listening on TCP shows a single **plug glyph** on
its row — never the port numbers. The row's job is *whether*, not *which*: the
numbers would compete with the diff and PR chips for the one line that matters,
and they are only actionable in a browser or a terminal. A branch serving nothing
draws no glyph at all. Colour is never the only signal: an attention dot and the
semantics label both name the state (something bound but not answering, or bound
past loopback).

Placement differs by platform on purpose. On the phone the glyph sits in the
branch line's trailing control column, ordered `branch · fold · ports · +`, so
`+` stays the last child and its column stays aligned down the card. On the
desktop it sits on the sub-row (the `PR #n · age` line), right-aligned on the
same 8 pt edge as line 1, because line 1's right edge already swaps between the
diff pill and the worktree menu on hover.

Opening it: **hover previews, click pins** on the desktop — hover after a short
dwell shows the list, and a click keeps it open so its buttons are reachable by
keyboard. On the phone, **tap, then tap**: the first tap lists the ports (rows
only, no buttons, so nothing is reachable from a flick), the second opens one
port's facts and its actions. Every terse token (`200`, `refused`, `exposed`)
carries one sentence, shown as a tooltip on the desktop, a long-press bubble on
the phone, and the screen-reader label on both.

Nothing is scanned unless somebody is looking: the scan is watch-gated, so no
`lsof` runs while the app is backgrounded or disconnected. This phase is
read-only — **Open** and **Copy URL**, both hidden when nothing answered HTTP
and there is therefore no honest URL to offer.

**Everything, all repos (SPEC-42).** Beside Home and Archived sits a **Ports**
screen (`⌘⇧P`, or the worktree menu's `Ports…`, which pre-selects *This repo*),
grouping every listener repo ▸ worktree ▸ port, with system listeners folded
away because they are noise, not work. Its filters are the two questions worth
asking — *Exposed* (what is reachable off this machine, makit's own listener
included) and *Orphans* (a dev server whose worktree is gone, which nothing but
you will ever reclaim) — plus *Mine* and *This repo*. A port two active
worktrees both claim carries the word `clash` and a banner naming the rival
branch; it never suggests a free port, and the screen never kills anything —
both are later phases. A port a container published names the **container**
instead of `com.docker.backend` and carries a `docker` token, while its reach
pill keeps reporting the real bind, because a published port on `0.0.0.0` is
exposed no matter who published it. On the desktop the same cached snapshot
feeds a `Ports (n)` menubar submenu with an `Open Ports…` item; the menubar
reads the cache and never arms the scanner, so a count only appears once some
surface has actually looked.

**Killing one (SPEC-43).** This is the first thing makit signals that it did not
spawn, so the whole design is about proving the process it kills is the one you
saw. The row you confirmed carries its own identity — address, port, pid **and**
start time — and the server ignores its cache, rescans, and re-matches all four
before sending anything; a pid that was reused or a server that restarted in the
meantime is refused, not killed. Only a listener a live worktree owns (or a known
orphan) is eligible: never a system listener, never pid 1, never makit itself or
its parents, never an agent session's own process — stop the session instead.
SIGTERM first; if it is ignored, makit waits, **re-verifies the identity again**,
and only then escalates to SIGKILL, so churn inside that window cannot redirect
the kill onto whatever took the port. The answer is specific — released,
force-killed, or *survived*, which means open a terminal rather than pretending it
worked. Desktop puts `Kill` last in the port row, red, and it still asks even
when the popover is pinned; the phone puts `Kill this process…` last in the
detail sheet, past a divider, a whole sheet away from the first tap. The confirm
names the command, pid, port and branch, because "Are you sure?" is not a
mitigation. A port whose start time makit could not read offers no Kill at all —
its identity is unverifiable. Every attempt is logged to stderr (device, endpoint,
signals, outcome) and never into a session's transcript. `Kill all orphans (n)`
in the orphans section is the same discipline N times over, behind one confirm
that names the ports, with an honest per-port result.

**Watching one (SPEC-44 P4a).** Port notifications are **opt-in per port**, from a
`Watch this port` switch in the detail sheet — an always-on version would fire
every time a build restarts a dev server, and would be muted within a day. A
watch is remembered by `(worktree, port)`, not by pid, so it survives exactly the
restart it is about, and it is persisted in `$MAKIT_HOME/watched-ports.json` by a
store that degrades to empty rather than failing startup. The alert fires only
after the port has been continuously gone — or bound-but-refusing — for twenty
seconds (about five scans); a recovery inside that window cancels it and re-arms,
so a rebuild is silent and a real outage is not. Exactly one notification per
outage. It carries the port number and nothing else, because a branch name on a
lock screen is the kind of content makit's push payloads deliberately cannot
contain. Only an owned port can be watched — an unowned listener has no stable
identity to watch by.

**Forwarding one to your phone (SPEC-44 P4b).** A loopback-only dev server is
invisible from your phone, and makit already holds a cert-pinned,
device-authenticated channel to the machine it runs on — so it can carry that port
over the connection it already has, without opening anything new on the host. On a
phone, a loopback port's `Open` is replaced by **Open in browser**: one tap mints
a grant and hands the URL to your own browser. The grant is bound to one port,
dies after 30 minutes whatever happens, and is reaped within a minute of the
preview going quiet; only a worktree-owned, loopback, HTTP-answering port is
eligible, and databases, shells and makit's own listener are refused outright.

Two costs the confirm states before you tap, because both are real. **The link is
the credential** — a browser cannot send makit's bearer, so the unguessable grant
id in the URL is what authorises it; every proxied response therefore carries
`Referrer-Policy: no-referrer`, so the previewed page cannot hand its own URL to a
site it links to. And **your browser will warn about the certificate**, because
makit signs its own and no browser can be taught to pin it; the alternative was a
second listener on the host, which is the thing makit promises not to do. Live
reload does **not** work and says so: the HMR socket is refused rather than
half-proxied, because a preview that silently stops updating is worse than one
that admits it is a snapshot.

The in-app WebView this originally specified is **not** what shipped. A WebView
uses the OS network stack, so it can neither pin the certificate nor attach the
bearer — which is why the design called for an HTTP proxy running inside the app,
and why that could not work: on iOS the app is suspended seconds after
backgrounding, which is exactly when a browser takes over. Going straight to the
desktop deletes the WebView, the in-app proxy and a native dependency, and leaves
the security work where it can be reviewed — on the server.

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
re-reading your own prompts must not mean scrolling blind. Each surface has one
affordance:

| | Desktop | Mobile |
|---|---|---|
| How you get back | the **ripple rail** over the transcript's top-right corner | **My messages** in the session-actions (`⋯`) menu → sheet, newest first, tap to jump |
| Configured by | rail switch + its three options in Settings › Agents & Chat | nothing — no mobile navigator settings |

Each app root *overrides* the shared style provider with what that surface can
offer; mobile leaves it at `off`, so the rail is unreachable on a phone by
construction rather than by a coercion call someone must remember. The rail is a
pointer design — it needs hover — and a phone has no screen to spend on permanent
chrome, so mobile uses a sheet from the actions menu instead. (A palette, a sticky
breadcrumb, an outline mode and an edge-drag scrubber were built and removed: four
alternate renderings of one jump is configuration standing in for a product
decision, and the scrubber asked a thumb for precision it lacks.)

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
