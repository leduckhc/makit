# SPEC-41 — Ports: what's listening, and whose branch owns it

**Status:** Implemented (P1, rev 2) · **Priority:** P2 · **Branch:** `feat/open-ports`
**Depends on:** SPEC-11 (repo-centric home), SPEC-19 (`ws/commands/*` split, `repo_service.ts`),
SPEC-32 (watch-gated cadence precedent), SPEC-37 (host-wide broadcast event, `metrics.watch`,
`proc_table.ts` / `tree.ts`, `Session.agentPid`)
**Mockups:** [`mockups/open-ports.html`](../../mockups/open-ports.html)

**Scope (P1 — this spec's implementation):**
*protocol:* `server/src/protocol.ts` (new `ports.snapshot` event kind + `PortDTO` /
`PortsSnapshotDTO`, `SessionEventKind` exclusion, `CmdKind` += `ports.watch`),
`server/src/protocol/codec.ts` (`EVENT_KINDS` **and** `HOST_ONLY_KINDS`).
*server:* `server/src/ports/` (new: `scan.ts`, `proc.ts`, `attribute.ts`, `health.ts`,
`service.ts`), `server/src/ws/commands/ports.ts` (new), `server/src/ws/commands/deps.ts`,
`server/src/ws/client.ts` (`watchingPorts`), `server/src/server.ts` (wiring + flag clear on
close), `server/test/fixtures/snapshots.json`, `test/e2e-server.ts`.
*app:* `app/lib/transport/codec.dart` (`PortsSnapshotFrame`), `app/lib/store/ports.dart`
(new), `app/lib/store/store.dart` (state slice + exhaustive `reduce`),
`app/lib/store/fake_server.dart`, `app/lib/ui/ports/` (new — vocabulary, glyph, popover, two
sheets), mounted in `app/lib/ui/home/worktree_row.dart` and
`app/lib/desktop/chat/desktop_sidebar.dart`.
*docs:* `docs/UX.md`.

---

## Goal

Answer two questions makit cannot answer today, from the phone or the desktop:

1. **Per branch:** is this worktree serving anything right now, and is it answering?
2. **Host-wide:** what is listening on this machine, and which branch owns it?

The unit of ownership is the **worktree**. `:5173` should read as *"the dev server
`feat/open-ports` started, answering 200, up 41 min"* — not "some node process".

## Why this belongs in makit

A multi-worktree workflow produces dev servers whose lifetimes are uncoupled from the
branches that spawned them: removing a worktree never kills its server, so 5173, 5174,
5175… accumulate for days, and then two branches fight for one port with an error that names
neither. makit already owns the two facts needed to attribute a socket to a branch — the set
of worktrees (`repo_service.ts`) and the process trees of the agents it spawned
(`Session.agentPid`, SPEC-37) — so it is the only tool on this machine that can.

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| D1 | **No glyph on the session tile in P1.** Worktree rows only. | One mount point, one provider read, one test surface. The session↔port link is real but it is not the question the row exists to answer. Revisit in P2 with the global screen. |
| D2 | **`reach` is `loopback` / `tailnet` / `exposed`, and `tailnet` requires an exact address match** with the tailnet IP the server already discovered. A wildcard bind is `exposed`, never `tailnet`. | A `0.0.0.0` listener is reachable from *every* interface; labelling it `tailnet` because Tailscale happens to be installed is a false negative on the more alarming reading. |
| D3 | **Health is probed only for ports attributed to a worktree**, minus a database deny-list, and only on the loopback form of the address. Everything else is simply not probed. | Sending `GET /` at every listening port on the machine would poke X11, VNC, SMTP, LDAP and TLS-only services, and would render a healthy HTTPS server as broken. The ports a branch owns are the ones the feature is about. |
| D4 | **No `wss` / protocol detection.** A plain `GET /` cannot produce a valid HTTP 101 and cannot prove TLS. | Truthfulness. An HTTP status code is a fact; a synthesised `wss` label is a guess. |
| D5 | **No `kind` guessing, no `rssBytes`.** The row shows the command; memory needs a rate story it does not have. | YAGNI. `command` already says `vite`. |
| D6 | **`key`, not `id`** — `<pid>:<address>:<port>` is a snapshot key, never persisted, and the UI re-selects by `(address, port)`. | PIDs are reused and a restart changes the PID for the same endpoint. Calling it an id invites callers to store it. |
| D7 | **`scanOk`, not `complete`.** It means "the scanner's commands ran", and the spec states plainly that attribution is best-effort: processes owned by other users, or protected by OS privacy policy, may be invisible even on a successful scan. | `lsof` exits 0 while omitting what it may not see. A field called `complete` would be a lie no implementation can make true. |

## Phasing

| Phase | Content | State |
| --- | --- | --- |
| **P1** | scan + attribution + (narrow) health; the row glyph; desktop popover; mobile list sheet → detail sheet; tooltips; `Open` + `Copy URL` | **this spec** |
| P2 | global Ports screen (filters), orphan + collision detection via port history, docker attribution, menubar, `Ports (n)…` in the worktree overflow menu, session-tile glyph | deferred |
| P3 | `ports.kill` (confirm-gated), kill-all-orphans, suggested free port | deferred |
| P4 | forward a loopback port over the WSS session; watched ports + notifications | deferred |

**P1 sends no signal to any process.** Killing something on your Mac from a phone on a train
is a remote-execution surface and does not ship in the same change as the scanner that finds
the processes.

## What P1 does not do

- No kill, no restart, no forwarding.
- No docker attribution — a published container port appears unowned (its listener is
  `com.docker.backend`, whose cwd is not a worktree). Honest, not wrong.
- No orphan or collision flags: both need port *history*, which needs a store (P2).
- No UDP, no established connections. Listeners are what a branch owns; the rest is traffic.
- No CPU%, no memory. Unmeasured is **absent**, never `0`.
- **No attribution for a process whose cwd is not the worktree**, even when its binary lives in
  one. Found during live verification: every macOS `.app` bundle launched by `flutter run` (three
  were listening on this machine, from three different worktrees) has `cwd = /`, so it reads as
  unowned. This is inherent to cwd-based ownership and is the right trade — the target case, a dev
  server started by `pnpm dev`/`vite` in a worktree, does carry the cwd, and inferring ownership
  from an executable path would attribute a *build artefact's* location rather than what is
  actually running. A P2 with port history could close the gap by remembering who bound the port.

## Attribution: how a port gets an owner

```
① lsof -nP -iTCP -sTCP:LISTEN -FpPnu        → listeners (pid, address, port, uid)
② ps -axo pid=,ppid=,etime=,args=           → whole-machine table (ppid, argv, etime)
        │   derive: listener pids ∪ their ancestors (bounded, cycle-safe)
③ lsof -a -d cwd -Fpn -p <that whole set>   → cwd per pid, ONE call
        │
        ├── own cwd ──longest-prefix (segment-wise)──▶ worktree ──▶ repo
        ├── else nearest ancestor's cwd, same rule   (pnpm→node, flutter→dart)
        └── else unowned
        │
④ pid ∈ descendants(session.agentPid) ──────▶ sessionId
```

**The cwd call must cover ancestors, not just listeners** — that was the first review's
blocker on rev 1: a `pnpm dev` parent owns the worktree cwd while the listening `node` child
may not, so a cwd map keyed only by listener pids makes the ancestor fallback dead code. The
ancestor set is derived from ② before ③ runs, so it is still one `lsof`.

**Longest-prefix on path segments.** `/a/b-2` must not match the prefix `/a/b`; a nested
repo must lose to its own worktree, not to its parent's. Both directions get a test.

**macOS path aliasing is real:** `/tmp` and `/var` are symlinks to `/private/...`, so a
process's cwd and a worktree path can name the same directory in two spellings. Both sides
are resolved with `fs.realpath` **once per distinct path, cached**, before comparison.

### What P1 reuses rather than rebuilds

| Need | Reused from |
| --- | --- |
| `Exec` seam (injectable runner; tests never spawn) | `metrics/proc_table.ts` `Exec` (structurally identical to `git.ts`'s `run`) |
| ppid → children index, cycle-safe descendant walk | `metrics/tree.ts` `childIndex` / `descendants` |
| elapsed-time parsing shapes (`dd-hh:mm:ss` ladder) | proven in `proc_table.ts` (`time=`; ours is `etime=`) |
| session root pids | `Session.agentPid` — already how SPEC-37 finds agent trees in `server.ts` |
| watch-gated cadence + flag cleared on socket close | `metrics.watch` (`ws/commands/metrics.ts`) |
| host-wide event excluded from the session log | `metrics.sample` — `SessionEventKind` **and** `HOST_ONLY_KINDS` |
| bounded fan-out | `concurrency.ts` `mapLimit`, as `repo_service.ts` uses it |

`proc_table.ts` is not reused as-is: it reads `comm=` (no argv) and `time=` (not `etime=`),
and it runs on SPEC-37's 1 Hz hot path. Widening that tick's `ps` for a 4 s feature would tax
the dashboard's hot loop for nothing.

## Wire contract

```ts
/** Where a listening socket can be reached from (D2). */
export type PortReach =
  | "loopback"  // 127.0.0.0/8 or ::1 — this machine only
  | "tailnet"   // bound to exactly the host's discovered tailnet address
  | "exposed";  // any other address, including wildcard: every interface

/** Verdict from one HTTP probe. Absent health means "not probed" (D3). */
export type PortHealthKind = "ok" | "http-error" | "refused" | "timeout";

export interface PortHealthDTO {
  kind: PortHealthKind;
  /** HTTP status when one was parsed (`200`, `404`, `500`); absent otherwise. */
  status?: number;
  /** Epoch ms of the probe that produced this verdict. Drives "probed Ns ago". */
  probedAt: number;
}

export interface PortDTO {
  /** Snapshot key, NOT an identity: `<pid>:<address>:<port>` (D6). Never persisted. */
  key: string;
  port: number;
  /** Bind address as reported: `127.0.0.1`, `0.0.0.0`, `*`, `::1`, `::`. */
  address: string;
  reach: PortReach;
  pid: number;
  /** Full argv, trimmed to `MAX_COMMAND_CHARS`. */
  command: string;
  /** Epoch ms the process started (from `etime`); absent when unparsable. */
  startedAt?: number;
  /** Absolute worktree path that owns this port; absent when unowned. */
  worktreePath?: string;
  /** Session whose process tree contains `pid`, when there is one. */
  sessionId?: string;
  /** Absent until probed, and absent forever for ports P1 does not probe (D3). */
  health?: PortHealthDTO;
  /**
   * Canonical URL to open, present only when something answered HTTP on this
   * port. Built server-side so the two clients cannot disagree:
   *   loopback / wildcard IPv4 → `http://127.0.0.1:<port>`
   *   `::1` / `::`             → `http://[::1]:<port>`
   *   a concrete address       → `http://<address>:<port>`
   * Absent ⇒ the UI hides `Open` and `Copy URL` rather than guessing.
   */
  openUrl?: string;
}

export interface PortsSnapshotDTO {
  /** Listening TCP ports, ascending by port then pid. */
  ports: PortDTO[];
  /** Epoch ms this scan completed. */
  scannedAt: number;
  /**
   * True when the scanner's commands ran (D7). It does NOT claim the whole
   * machine was visible: `lsof` can exit 0 while omitting processes owned by
   * other users or shielded by OS privacy policy. Attribution is best-effort.
   */
  scanOk: boolean;
  /** One-line reason when `scanOk` is false — rendered in the glyph's tooltip. */
  scanError?: string;
}
```

`ports.snapshot` is a **host-wide broadcast event**. Both halves of the carve-out are
required, and this is the third instance of it: the compile-time `SessionEventKind`
`Exclude<>` in `protocol.ts` **and** the runtime `HOST_ONLY_KINDS` set in
`protocol/codec.ts`. Adding only the former lets `decodeSessionEvent` accept a
`ports.snapshot` and persist a machine-wide broadcast into a session's append-only log.
A test asserts the rejection.

**Snapshot, not delta.** ~11 ports ≈ 2 KB, at most every 4 s, only while watched. Deltas
would buy a rounding error of bandwidth for an ordering contract and a resync path.

**Fixture placement:** the round-trip golden goes in `server/test/fixtures/snapshots.json`,
**not** `events.json` — `contract.test.ts` asserts `events.json` covers every *session* kind
exactly once and feeds each entry to `decodeSessionEvent`, so a host event there fails both
assumptions (and the Dart mirror's too).

## Delivery: watch-gated, never ambient

`ports.watch {on: boolean}`, mirroring `metrics.watch`:

- sets `client.watchingPorts`; **also cleared on socket close** in `server.ts` (a window
  killed with the popover open never sends `{on:false}`, and a leaked flag would poll `lsof`
  forever);
- on a false→true transition the client is sent the cached snapshot immediately **and** the
  service starts exactly one scan, so a freshly-mounted list paints from cache and refreshes
  within one scan rather than waiting a whole tick;
- a repeated `{on:true}` neither re-sends nor re-scans;
- the service polls at `SCAN_INTERVAL_MS` (4 s) **only while `watchers > 0`**; at zero it
  disarms its timer and does no work at all;
- **scans never overlap.** A tick that fires while a scan is in flight is skipped, not
  queued;
- a publish with zero watchers is a no-op, so an in-flight scan that finishes after the last
  watcher leaves cannot re-arm anything.

**Why ports are not folded into `WorktreeDTO`.** The repos snapshot is recomputed on
worktree changes, PR-watcher ticks and every spawn, and is documented as "an occasional
operation, not per-event". Hanging a 3-process scan off it would make those refreshes slower
for everyone *and* leave port data stale exactly when it is being looked at.

**Accepted consequence:** the glyph is live only while something holds the watch. P1 holds it
while the home screen / sidebar is mounted (ref-counted, like `MetricsWatch`), so no `lsof`
runs when the app is backgrounded or disconnected.

### Cost

One scan = 3 `exec`s, whole-machine, independent of worktree count. Measured on this machine
during review: listener `lsof` ≈ 60 ms, listener + cwd batch ≈ 110 ms; `ps -axo` is the
third and is the same call SPEC-37 already affords at 1 Hz. Every exec carries a timeout.
Health probes run **after** the snapshot is published and land on the next tick —
stale-while-revalidate, the same discipline `includePrs` uses in `repo_service.ts`: local
socket facts are instant, a network op must never be on the path that returns them.

## Health probing (deliberately narrow — D3)

Probed **only** when `worktreePath` is set, the port is not in `NO_HTTP_PROBE_PORTS`
(22, 5432, 3306, 6379, 27017, 11211), and the address has a loopback form to talk to. One
`GET / HTTP/1.1` + `Connection: close`, `PROBE_TIMEOUT_MS` = 800, reading only far enough to
parse the status line, capped at `PROBE_CONCURRENCY` = 12, cached for `PROBE_TTL_MS` = 10 s.

| Result | `kind` | Rendered |
| --- | --- | --- |
| HTTP 2xx/3xx | `ok` + `status` | `200` |
| HTTP 4xx/5xx | `http-error` + `status` | `404` |
| `ECONNREFUSED` | `refused` | `refused` |
| no status line in 800 ms | `timeout` | `timeout` |
| not probed (unowned, deny-listed, or first tick) | *no health* | nothing |

The deny-list is not protocol detection: it is a short courtesy list of ports where an HTTP
request is known log-noise, and being wrong about one costs only a missing verdict. It is one
constant with a comment, not a setting.

## App surface

`StoreState.ports: PortsSnapshot?` (null before the first frame), one `PortsSnapshotFrame`
`Decoded` variant, one arm in the exhaustive `reduce`. Derived selectors, never recomputed in
a widget: `portsForWorktreeProvider(path)`, `portsGlyphStateProvider(path)`,
`portsWatchProvider` (ref-counted `PortsWatch`).

### The row: one glyph, no numbers

Port numbers are **not** rendered in either row: a row's job is *whether*, not *which*.
Numbers compete with the diff and PR chips for the one line that matters, and are only
actionable in a browser or a terminal — both already one interaction away. The glyph is
Phosphor **`Plug`** (`PhosphorIconsLight.plug`), the app's existing weight. State is carried
by tint **and** an attention dot **and** the semantics label — never colour alone
(`worktree_row.dart`'s existing rule).

**Mobile** (`worktree_row.dart`): trailing control column of the branch line, order
`branch · fold · ports · +`. `+` stays the last child so its column stays aligned down the
card (`kTrailingControl` = 30); the glyph is a one-child insert before it. It does **not** go
on the meta line, which that file documents as "not a target".

**Desktop** (`desktop_sidebar.dart`): the **sub-row**, right-aligned. Line 1's right edge is
already a swapping slot (`DiffChip` idle ⟷ `_WorktreeMenuButton` on hover/focus/menu-open),
so a persistent glyph cannot live there. The sub-row pads `fromLTRB(46, 0, 8, 4)` and line 1
pads `fromLTRB(6, 6, 8, 2)` — the **same 8 pt right edge** — so a right-aligned glyph forms a
column under the swap, costs the branch name nothing at any sidebar width (250–450), and
grows no row: that line is already a fixed, always-reserved 16 pt.

**The target is 22 × 16 pt — wider, not taller.** Rev 1 claimed a 22 pt hit box overflowing
into neighbouring padding; review proved that false: hit testing is bounded by the parent's
size, so an `OverflowBox` would paint outside and still not receive the pointer. The glyph
therefore takes width it can have (22) and lives with the height the row already reserves
(16), which is below the 20 pt guideline in one axis. Accepted for a pointer-only surface,
recorded here rather than hidden; the fallback, if it reads badly in use, is to raise the
sub-row to 20 pt for **every** row (4 pt × N) rather than make one row taller than its
siblings.

The platform divergence (branch line on phone, sub-row on desktop) is deliberate: the
phone's meta line cannot host a tap target, the desktop's sub-row can host a pointer target.

### Opening it: hover previews, click pins (desktop) · tap, then tap (mobile)

**Desktop** — one popover, every action visible per row, because a trackpad can hit a 24 pt
button in a list. Hover opens after `HOVER_OPEN_MS` = 350 (sliding down eight worktrees fires
nothing); the gap between glyph and popover is inside the hover region so travelling into the
buttons cannot dismiss it; leaving both starts `HOVER_CLOSE_MS` = 150 of grace; **clicking
pins** until `esc`, an outside click, or a second click — which is what makes the buttons
keyboard-reachable (`⇥`) instead of a hover-only trap.

**Mobile** — two sheets. Sheet 1 is a 56 pt-row list with chevrons and **no buttons**:
nothing actionable is reachable from a flick. Sheet 2 is one port — every fact as a labelled
row (worktree, session, command, pid, uptime, bound address, probe) then `Open` and
`Copy URL`, which are hidden when `openUrl` is absent.

### Tooltips: every terse token owns a sentence

`200` is not self-explanatory. Each short token has **one** string, used by three consumers —
desktop `Tooltip`, mobile long-press bubble, `Semantics.label` — living in
`ui/ports/ports_vocabulary.dart` so they cannot drift. The tooltip is also where
**freshness** lives, which a pill cannot carry: `HTTP GET / → 200 OK · probed 4 s ago`.
Rules: `TOOLTIP_DWELL_MS` = 500 (never races the popover's 350), one at a time, and **no
tooltip on a control that already says what it does** (`Open`, `Copy URL` get none).

### Two traps the existing code already documents

1. **The hover latch.** `_WorktreeGroupState` keeps `_hovering`, `_focused` *and*
   `_menuOpen`, with a comment warning that an open popup's barrier steals mouse-hover and
   flips `_hovering` off. The ports popover has the same shape and needs the same latch
   (`_portsOpen` OR-ed in), or opening it un-hovers the row and the `…` snaps back to a diff
   pill under the cursor.
2. **`Clipboard.getData` has no default test mock** (project skill): an un-mocked call
   *hangs* rather than fails. Any test asserting `Copy URL` installs a
   `SystemChannels.platform` handler.

## Tests

| Layer | Test |
| --- | --- |
| `protocol/contract.test.ts` | `ports.snapshot` round-trips via `decodeFrame` from `snapshots.json`; **`decodeSessionEvent` rejects it** (the `HOST_ONLY_KINDS` half) |
| `codec_contract_test.dart` | the same fixture decodes in Dart — byte-identical both ways |
| `ports/scan.test.ts` | `-F` parse: state persists across `f`/`P`/unknown records; one `p` with many `n`s; `*:5173`; `[::1]:9787` → `::1`; non-numeric port skipped not thrown; spawn failure → `scanOk:false` + one-line reason; non-zero exit *with* parsed listeners still yields those listeners |
| `ports/proc.test.ts` | argv with spaces survives whole; `etime` `mm:ss` / `hh:mm:ss` / `dd-hh:mm:ss` → `startedAt`; unparsable `etime` **omits** it (never epoch 0); malformed line skipped, rest kept; `readCwds([])` runs **no command** (an empty `-p` would dump the machine) |
| `ports/attribute.test.ts` | listener whose **parent** owns the cwd is attributed (the rev-1 blocker); longest-prefix beats ancestor repo; `/a/b-2` ∌ `/a/b`; `/tmp` vs `/private/tmp` resolve equal; ancestor walk is cycle-safe and bounded; pid in `descendants(agentPid)` → `sessionId`; unowned stays unowned; `reach` ladder incl. wildcard → `exposed` **not** `tailnet`, and exact tailnet IP → `tailnet`; `openUrl` for `127.0.0.1`, `*`, `::1`, concrete address, and **absent** with no HTTP verdict |
| `ports/health.test.ts` | 200 → `ok` + status; 404 → `http-error`; refusal → `refused`; a hang → `timeout` at 800 ms; **unowned port is never probed**; deny-listed port is never probed; verdict cached 10 s then re-probed; a malformed status line is `http-error`, not a throw; concurrency cap respected |
| `ports/service.test.ts` | zero watchers → **no exec at all**; 0→1 triggers exactly one immediate scan; ticks at 4 s while watched; a tick during an in-flight scan is skipped; 1→0 disarms; a scan finishing after the last watcher leaves publishes nothing; identical snapshot does not re-broadcast; a throwing scan keeps the last good snapshot and sets `scanOk:false` |
| `ports/acceptance.test.ts` | **machine-verifiable attribution:** create a temp git worktree, start a real `node` listener with `cwd` set to it, run the real scanner, assert that port's `worktreePath` is that worktree. Skipped with a reason if `lsof` is unavailable |
| `ws/commands/ports.test.ts` | `{on:true}` acks + sends one snapshot + arms; repeat `{on:true}` does neither; `{on:false}` disarms; socket close clears the flag; a malformed payload (`on: "yes"`) is a no-op, not a crash |
| `store/ports_test.dart` | `fromJson` drops non-numeric fields; absent `health`/`openUrl`/`startedAt` stay absent; reducer latest-wins; `portsForWorktreeProvider` filters + sorts; glyph-state ladder incl. the `scanOk:false` unknown; `PortsWatch` sends one `{on:true}` for N holders and one `{on:false}` on the last release |
| `ui/ports/ports_vocabulary_test.dart` | every `PortHealthKind` and `PortReach` has a non-empty sentence; probe age appears in the health string; no-health renders the not-probed sentence; `Open`/`Copy URL` have no tooltip |
| `ui/ports/ports_glyph_test.dart` | nothing rendered when a worktree has no ports; attention dot on `refused`; semantics label names the state (never colour alone); the desktop glyph is hit-testable at 22 × 16 **and** the sub-row's height is unchanged |
| `ui/ports/ports_popover_test.dart` | 350 ms dwell before open; travelling into the popover keeps it; click pins past a pointer exit; `esc` closes; row stays hovered while pinned (`_portsOpen`); `Open`/`Copy URL` hidden without `openUrl` |
| `ui/ports/ports_sheets_test.dart` | sheet 1 has no buttons; tapping a row opens sheet 2; sheet 2 lists every fact; no destructive control exists in P1 |
| `integration_test/stub/ports_test.dart` | full-stack: stub server publishes a snapshot → glyph on the seeded worktree's row → tap lists the port → tap shows the command |

`test/e2e-server.ts` publishes a deterministic snapshot (one worktree-owned port) so the e2e
loop exercises the real frame path rather than an indicator nothing feeds — the reason
SPEC-37 gave `StubAdapter` a usage ramp. `fake_server.dart` mirrors it for widget work.

## Verification (beyond unit tests)

Per project skill `makit-verify-feature-end-to-end`, unit tests here can pass while the
feature is dead:

1. `cd server && node_modules/.bin/tsc -p . --noEmit && npm test`
2. `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub`
3. `ports/acceptance.test.ts` — the scripted real-listener-in-a-real-worktree check above.
   This replaces rev 1's "compare by eye", which was not machine-verifiable.
4. A live eyeball on top of (3), because only a human notices a *plausible but wrong* owner:
   the snapshot printed against `lsof -nP -iTCP -sTCP:LISTEN` on a machine with several
   worktrees serving at once.
5. `tool/e2e.sh --mode=stub` with the new case registered in `all_stub_test.dart`.

### Results (2026-08-06)

| Check | Result |
| --- | --- |
| `tsc --noEmit` + `npm test` | clean · **1007 pass / 0 fail** (918 pre-existing + 89 new) |
| `flutter analyze --fatal-infos` + `flutter test` | clean · **1797 pass** (1729 pre-existing + 68 new) |
| `ports/acceptance.test.ts` (real `lsof`, real listener, real worktree) | pass in 259 ms |
| Live snapshot vs `lsof -nP -iTCP -sTCP:LISTEN` (§4) | 33 listeners seen, 30 cwds resolved, `:9749` correctly attributed to the `fix-token-usage` worktree. Surfaced the `cwd = /` limitation recorded above. |
| Real WSS frame path (`hello` → `ports.watch` → `ports.snapshot`) | verified: snapshot arrives, deterministic port attributed |
| `tool/e2e.sh --mode=stub` | **not run** — needs an iOS simulator; the integration case is written and registered. Pre-existing harness breakage on this branch (same as SPEC-37 recorded). |

## Review findings applied (rev 1 → rev 2)

Two independent reviews (codex, correctness + engineering-practice) produced 20 findings.
Accepted and folded in: the ancestor-cwd blocker (③ now covers ancestors);
`HOST_ONLY_KINDS`; the fixture belongs in `snapshots.json`; `complete` → `scanOk` with
best-effort stated; probing narrowed to worktree-owned ports (X11/VNC/SMTP/TLS risk);
`wss`/`protocol` cut; `reach` fixed for wildcard binds; `id` → `key`; `probedAt` only on a
real probe (health now optional); `openUrl` defined server-side; immediate-scan +
no-overlap + teardown semantics; `kind` and `rssBytes` cut; magic numbers named; locked
decisions table; machine-verifiable acceptance test; the 22 pt hit box corrected to 22 × 16
with the reason; parser state across `f`/`P` records; plan re-ordered so the contract test
is red first and vocabulary precedes the glyph.

Rejected, with reason: **cut the health probe entirely** — the `200`/`404` reading and its
tooltip are the feature's most-used fact, and D3 removes the risk that motivated the cut;
**cut the tooltip vocabulary module** — it has exactly three real consumers today, which is
the opposite of speculative; **cut hover-dwell and click-to-pin** — hover-only cannot host
buttons accessibly and click-only loses the glance, both of which were considered and
recorded in the mockups.
