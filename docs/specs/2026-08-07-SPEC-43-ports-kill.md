# SPEC-43 — Ports P3: kill a listener you can see, safely

**Status:** Draft · **Priority:** P2 · **Branch:** `feat/open-ports-kill`
**Depends on:** SPEC-41 (open ports — scan, attribution, `PortDTO`/`PortsSnapshotDTO`,
`ports.watch`, the popover + the two mobile sheets), SPEC-19 (`ws/commands/*` split,
`CommandRouter`, `CommandDeps`), SPEC-07 (paired-device bearer + `DeviceRegistry`).
**Soft-depends on:** SPEC-42 (orphan + collision detection via port history) — required **only**
for kill-all-orphans and the suggested-free-port helper; the single-port kill needs none of it.
**Mockups:** [`mockups/open-ports.html`](../../mockups/open-ports.html) — §2a (desktop `Kill`,
position fixed, still confirms), §2b sheet 2 (`Kill this process…` past the `danger` divider),
§6 (`Kill all orphans`), §10 (auto-kill + inline mobile kill buttons **rejected**).

---

## Goal

SPEC-41 P1 shipped the scanner and said, in as many words:

> **P1 sends no signal to any process.** Killing something on your Mac from a phone on a train is
> a remote-execution surface and does not ship in the same change as the scanner that finds the
> processes.

This is that change. It adds exactly one new capability — terminate a **listening process the
user can already see and has explicitly confirmed** — and spends its entire design budget on the
one hazard that capability creates: **the pid the user saw may not be the pid the server signals.**

The unit of action stays the worktree. The target case is a wedged or forgotten dev server —
`:5175 vite · refused, up 6h` (§6) — that the user wants gone without opening a terminal.

## Why this is the security-sensitive phase

Everything before P3 was read-only: a wrong answer showed a misattributed row. A wrong answer here
sends a signal to the wrong process. SPEC-41's **D6** is load-bearing:

> **`key`, not `id`** — `<pid>:<address>:<port>` is a snapshot key, never persisted … PIDs are
> reused and a restart changes the PID for the same endpoint.

So a kill command that names a pid is a time-of-check-to-time-of-use bug by construction: between
the scan that produced the row and the frame that consumes it, that pid may belong to something
else. The whole spec is the answer to *"prove the process you are about to signal is the one the
user saw."*

makit already solves this shape twice, and this spec reuses both disciplines rather than inventing:

- **`wrap_up.dart`** ships an `expectBranch` with every branch-deleting command *"so … the user
  could [not] confirm 'delete feat/x' and have a different branch deleted — one they checked out
  since the snapshot. The server resolves the branch again when it runs."* — confirm names it,
  command carries it, server re-verifies it.
- **`daemon/service.ts`** *"only SIGTERM[s] when the control socket confirms a makit daemon whose
  pid matches the PID file. After a crash the OS may recycle the pid onto an unrelated process."*

## What makit does with process signals today (so P3 raises the bar honestly)

There is **no** existing path that signals an arbitrary pid. `manager.killSession` →
`session.adapter.kill()` → `child_transport.dispose()` → `child.kill("SIGTERM")` signals **a child
process makit itself spawned and holds a live handle to**, never a pid discovered by scanning. The
daemon's `stop` SIGTERMs **its own recorded pid**, behind the reuse guard quoted above. `ports.kill`
is therefore the **first** place makit will signal a process it did not spawn and holds only a
scanned pid for. That is exactly why D1's re-verification, D3's whitelist and D8's confirm are
non-negotiable rather than nice-to-have.

## Decisions (locked before implementation)

| # | Decision | Why |
| --- | --- | --- |
| **D1** | **Re-verify identity on a fresh scan immediately before signalling.** The client sends the full tuple `{address, port, pid, startedAt}` it displayed. The server **ignores its ≤4 s cache**, runs one fresh authoritative scan on the kill path, and re-matches **all four** fields. Any mismatch — pid reused, process restarted, endpoint already free — is a typed refusal (never a signal). | D6: the key is ephemeral because pids are reused and a restart changes the pid for the same endpoint. This is precisely `wrap_up.dart`'s `expectBranch` and `daemon/service.ts`'s pid-reuse guard. **Accepted failure mode:** a process that exits and is replaced at the same `(address, port)` by a listener whose pid *and* 1-second-granularity `startedAt` both collide within one round-trip would be mis-killed — practically unreachable, and strictly safer than matching on `(address, port)` alone. |
| **D2** | **SIGTERM, then SIGKILL after a re-verified grace window.** Send SIGTERM; wait `KILL_GRACE_MS`; **re-scan and re-run D1**; only if the same identity still holds, send SIGKILL; re-scan once more. The ack carries a terminal outcome: `released` (gone after SIGTERM) · `force-killed` (needed SIGKILL) · `survived` (still listening after SIGKILL, e.g. `EPERM`/foreign uid). | `session.kill` is SIGTERM-only because makit owns the child and the agent exits cleanly. A foreign dev server the user *explicitly confirmed* killing may ignore SIGTERM — that is the wedged-zombie the feature targets — so a bounded escalation earns its keep. Re-running D1 before the SIGKILL is what makes the grace window safe: pid churn in that window can never redirect the SIGKILL onto a recycled pid. `survived` tells the user to reach for a terminal instead of reporting a false success. |
| **D3** | **The killable set is a server-enforced whitelist, checked on the fresh scan** (see the refusal table below). Only a listener attributed to a **live worktree** (`worktreePath` set) — or, once SPEC-42 lands, a known **orphan** — may be signalled. Never an unowned/system listener, never pid 1, never makit's own server pid or any ancestor of it, never a session's agent-root pid. | The most important table in this spec. A whitelist fails safe: an endpoint the server cannot positively classify as a user-owned dev server is refused, not signalled. It also confines the blast radius to exactly `worktree.remove`'s (a worktree's own processes), which is why D4 needs no extra gate. |
| **D4** | **A paired-device bearer is sufficient. No new server flag, no per-command opt-in.** In `--no-auth`/`trustLocalhost` dev mode a **loopback** client may kill. | A paired device can already `send.message` to a `yolo`/`ask-on-risky` session — arbitrary tool/shell execution — plus `session.kill` and `worktree.remove`. `ports.kill`, confined by D3 to a SIGTERM on a worktree-owned dev server, grants **strictly less** than the RCE the bearer already carries; a dedicated flag would harden the least-dangerous door while `send.message` stays wide open — theatre, plus a maintenance and discoverability cost (YAGNI, add-a-flag direction). The stolen-unlocked-phone threat is real and is met the *same* way every destructive action meets it: a confirm that names the specific target (D8), which the same thief's session already bypasses for worse. A loopback client under `--no-auth` **is** the local user, who already has `kill(1)`; refusing them protects nothing — recorded explicitly because an unstated dev-mode carve-out is how a hole ships by accident. |
| **D5** | **Kill-all-orphans is N re-verified single kills, not atomic, and hard-depends on SPEC-42.** It **cannot exist before SPEC-42**: "orphan" is undefined without port history. When available, `ports.killOrphans` enumerates the current orphan set, applies D1–D3 to each **independently**, and returns a per-endpoint outcome array; one failure never aborts the batch. Confirmed once, naming the count and the ports. | You cannot roll back a signal, so "atomic bulk kill" is meaningless — the honest contract is per-endpoint outcomes. Gating it behind SPEC-42 is what lets the single-port kill (P3a) ship now (see Phasing). |
| **D6** | **The suggested-free-port helper moves to SPEC-42**, not this spec. | `base + hash(branch)` skipping taken ports is cheap, pure and non-destructive, and the mockup only ever renders it **inside the collision banner** (§2b: *"free here: 5183"*), which needs the port-history collision detection that lands in SPEC-42. It has nothing to do with termination; folding a harmless helper into the one spec whose review must concentrate on destruction dilutes that review. A deliberate refinement of SPEC-41's P3 phasing row (separation of concerns). |
| **D7** | **Every kill attempt is logged to stderr via `log.ts`; never to the session event log.** One `log.info` on success / `log.warn` on refusal or `survived`, carrying: device id, `address:port`, pid, `startedAt`, signal(s) sent, outcome. Metadata only. | A destructive remote action must be auditable. It is a **host** event, so it stays out of the append-only session log by the same `HOST_ONLY_KINDS` discipline SPEC-41 established (`metrics.sample`/`ports.snapshot`). The argv is already public in the snapshot, so it may appear; nothing secret is logged, mirroring `session.ts`'s "never the message text" rule. |
| **D8** | **Confirm on both platforms, client-side, naming process + port, destructive control last / behind a divider.** A `showDialog` `AlertDialog` (the `session_tile`/`worktree_actions`/`wrap_up` precedent) whose title and body name the exact command, pid and port — **not** "Are you sure?". The tuple the dialog names **is** the `{address, port, pid, startedAt}` the command sends (the `expectBranch` precedent). Desktop: `Kill` stays the **last** action in the popover row, red-wash, and still confirms even when the popover is pinned. Mobile: `Kill this process…` stays the **last row of sheet 2, past the `danger` divider**. No inline kill in the scrollable list. | The mockup fixes this exactly (§2a "the pin makes it reachable, not one-click"; §2b "~420 pt below the first tap, behind a confirm"), and §10 rejects both auto-kill and inline mobile kill buttons. A confirm the user can read and that names the victim is the stolen-device mitigation. |

## Phasing (this spec is internally phased so P3a ships without SPEC-42)

| Phase | Content | Depends on |
| --- | --- | --- |
| **P3a** | Single-port `ports.kill` — D1 re-verify, D2 escalation, D3 whitelist, D4 auth, D7 audit, D8 confirm; desktop popover `Kill`, mobile sheet-2 `Kill`. **Independently shippable.** | SPEC-41 only |
| **P3b** | `ports.killOrphans` (D5) + the orphans section's `Kill all orphans (n)` button (§6). | **SPEC-42** (orphan set) |
| — | Suggested free port (D6). | moved to **SPEC-42** |

**P3a is useful without SPEC-42:** a wedged dev server whose worktree still exists — the §6
`:5175 vite · refused, up 6h · fix/scroll-anchor` case — is `worktreePath`-attributed and therefore
killable today. Reclaiming a true *orphan* (whose worktree was removed, so `worktreePath` is absent)
returns `not_owned` until SPEC-42 supplies the orphan set; that is the crisp, stated limitation.

## What P3 does not do

- **No auto-kill.** SPEC-41 §10 rejects *"auto-killing idle servers … too clever, too destructive
  — offered as a reviewable list instead, never automatic."* Nothing here fires without a confirm.
- **No killing an arbitrary pid.** The command takes an endpoint tuple, not a raw pid, and D3
  refuses anything the fresh scan does not classify as a user-owned dev server.
- **No killing unowned/system listeners, pid 1, makit's own server, makit's ancestor tree, or a
  session's agent-root pid.** (Kill the agent through `session.kill`, which owns that lifecycle.)
- **No SIGKILL without a preceding, re-verified SIGTERM** (D2).
- **No inline kill button in the mobile list** (§10 fat-finger trap) — sheet 2 only, last, behind
  the divider.
- **No `Stop container`** (the mockup's docker row action). Docker attribution is SPEC-42; without
  it there is no container to name, so it is deferred with docker.
- **No suggested-free-port** (D6 → SPEC-42) and **no kill-all-orphans before SPEC-42** (D5).
- **No restart / no forwarding / no watched-port notifications** (the mockup's `Restart` and
  `Watch this port` are P4).
- **No new event kind and no session-log entry.** The outcome returns on the command ack; the
  cache-invalidating refresh rides the existing `ports.snapshot` broadcast (see below).

## Wire contract

Additive to `server/src/protocol.ts` (`CmdKind`) and its Dart mirror. No new `EventKind`.

```ts
export type CmdKind =
  | /* …existing… */
  /**
   * SPEC-43: terminate one listening process the user is looking at. Carries the
   * full identity tuple captured from the snapshot; the server re-verifies it on a
   * FRESH scan before signalling (D1) and refuses on any mismatch. Request/ack —
   * the ack body carries a `PortKillResult`.
   */
  | "ports.kill"
  /** SPEC-43 P3b (needs SPEC-42's orphan set): kill every current orphan (D5). */
  | "ports.killOrphans";
```

```ts
/** The endpoint the client confirmed killing, captured from the row it displayed. */
export interface PortKillTarget {
  address: string;
  port: number;
  pid: number;
  /**
   * Epoch ms the process started (`PortDTO.startedAt`). REQUIRED here even though it
   * is optional on `PortDTO`: a listener whose `startedAt` was unparsable cannot be
   * identity-verified (D1), so the UI must not offer to kill it and the server refuses
   * a target that omits it.
   */
  startedAt: number;
}

/**
 * Terminal outcome of one kill, returned on the `ports.kill` ack (and, for
 * `ports.killOrphans`, one per endpoint). Refusals are OUTCOMES, not `err` frames:
 * the UI renders each specifically ("that process changed since you looked — rescan"),
 * which a generic error cannot carry. `err bad_request` is reserved for a malformed
 * payload; `err internal` for an unexpected throw (never reached in normal operation).
 */
export type PortKillOutcome =
  | "released"          // gone after SIGTERM
  | "force-killed"      // survived SIGTERM, gone after SIGKILL
  | "survived"          // still listening after SIGKILL (EPERM / foreign uid)
  | "not_found"         // no listener at (address,port) in the fresh scan — already gone
  | "identity_mismatch" // (address,port) present but pid/startedAt differ (D1) — pid reuse / restart
  | "not_owned"         // matched pid has no worktree (and is no known orphan) (D3)
  | "refused_protected" // matched pid === 1 (D3)
  | "refused_self"      // matched pid is makit's server pid or an ancestor of it (D3)
  | "refused_session"   // matched pid is a session agent-root — use session.kill (D3)
  | "scan_unavailable"; // the fresh kill-path scan failed (lsof/ps unavailable) — refuse, never guess

export interface PortKillResult {
  outcome: PortKillOutcome;
  /** Echo of the target so the app can re-select the row by (address, port). */
  address: string;
  port: number;
}

/** P3b only. */
export interface PortKillOrphansResult {
  results: PortKillResult[];
}
```

**Cache invalidation.** After any outcome that actually released an endpoint
(`released`/`force-killed`), the server asks the `PortsService` for **one immediate re-scan +
broadcast** so every watching client's list updates within the round-trip rather than up to
`SCAN_INTERVAL_MS` later. A refusal broadcasts nothing.

**Not a session event.** No `EventKind` is added, so the `SessionEventKind` `Exclude<>` /
`HOST_ONLY_KINDS` carve-out is untouched — a kill leaves no trace in any session's append-only log,
by construction (D7).

## The killable whitelist (D3) — refusal rules, each one testable

Checked against the **fresh** kill-path scan (`listListeners` → `readProcs` → `readCwds` →
`attribute`), never the cache. Rules are evaluated in order; the first that fires wins.

| # | Refuse when | Outcome | Mutation that proves the test bites |
| --- | --- | --- | --- |
| **R1** | the fresh scan failed (`scanOk:false` — `git.ts`'s `run()`/`listListeners` resolve `{ok:false}` on a missing/timed-out `lsof`, they never reject) | `scan_unavailable` | make the handler **fall back to the cached snapshot** when the fresh scan fails → the test injects an `lsof` spawn fault and asserts **no signal** + `scan_unavailable` |
| **R2** | no listener at `(address, port)` in the fresh scan | `not_found` | signal the client-supplied pid **without** requiring a fresh match → test kills an endpoint absent from the scan |
| **R3** | a listener at `(address, port)` exists but its `pid` **or** `startedAt` ≠ the target tuple | `identity_mismatch` | match on `(address, port)` **only**, ignoring `pid`/`startedAt` → test: same endpoint, recycled pid → asserts **no signal** |
| **R4** | the matched pid has **no `worktreePath`** (and is not a SPEC-42 orphan) | `not_owned` | drop the ownership check → test a system listener (e.g. `sshd`, no `worktreePath`) → **no signal** |
| **R5** | the matched pid `=== 1` | `refused_protected` | remove the `pid === 1` guard → test |
| **R6** | the matched pid is the **server pid** or an **ancestor** of it (walk `ppid` via `ancestors.ts`) | `refused_self` | remove the self/ancestor guard → test a kill targeting `process.pid` and one targeting its parent → **no signal** |
| **R7** | the matched pid ∈ `listSessionRoots()` (a session's agent-root) | `refused_session` | remove the session-root guard → test → **no signal** (and the message points at `session.kill`) |
| **R8** | *(escalation guard, not an outcome)* before the SIGKILL, D1 no longer matches | reported `released` | skip the pre-SIGKILL re-verify → test: pid exits + is reused during `KILL_GRACE_MS` → asserts SIGKILL is **not** sent to the recycled pid |

A pid owned by a **different uid** is not a separate pre-check: `process.kill` raises `EPERM`, which
surfaces as `survived` (D2). Adding a uid gate would duplicate the OS's own check and depend on an
`lsof` field that may be absent (YAGNI).

Constants (named, one place, with comments — SPEC-41's convention):
`KILL_GRACE_MS` = `2_000` (SIGTERM→SIGKILL window); the kill-path scan reuses the service's
`EXEC_TIMEOUT_MS`.

## Server shape

`PortsService` grows the kill orchestration because it already owns the scan seam, the injected
`exec`, the worktree/session sources and the clock — and owning it there keeps the pure whitelist
next to the code that produced the snapshot it guards.

- **`classifyKillTarget(target, freshScan, guards)` — pure, no I/O.** Applies R1–R7 against a
  fresh `PortDTO[]` plus `{serverPid, serverAncestors: Set<number>, sessionRoots: Set<number>}`
  and returns a decision: `{signal: true, pid}` or `{signal: false, outcome}`. This is the unit
  under the refusal-table test; it cannot signal anything.
- **`PortsService.killPort(target): Promise<PortKillResult>` — the orchestrator.** Runs the fresh
  scan (R1 short-circuits on `scanOk:false`), calls `classifyKillTarget`, and on a `signal`
  decision: `signal(pid, "SIGTERM")` → `sleep(KILL_GRACE_MS)` → fresh scan + re-classify → if still
  matched `signal(pid, "SIGKILL")` → fresh scan → map to `released`/`force-killed`/`survived`. Every
  `signal` call is wrapped (`process.kill` throws `ESRCH`/`EPERM`): `ESRCH` after SIGTERM ⇒ the
  process is gone ⇒ `released`; `EPERM` ⇒ `survived`. Injected deps (defaults in parens) keep tests
  from ever spawning or signalling: `signal` (`process.kill`), `sleep` (`setTimeout`-backed).
- **`PortsService.killOrphans()` (P3b)** maps `killPort` over the orphan set SPEC-42 supplies;
  independent per-endpoint results (D5).
- **`ports.kill` handler** (`ws/commands/ports.ts`, beside `ports.watch`): parse + validate the
  four tuple fields (any missing/non-numeric ⇒ `err bad_request`, the `metrics.watch` malformed-
  payload discipline), `ctx.ack(await deps.killPort(target))`, then on a releasing outcome ask the
  service for an immediate re-scan/broadcast. `CommandDeps` grows `killPort` (and P3b `killOrphans`),
  wired in `server.ts` from the existing `portsService`, `manager.allSessions()` (session roots) and
  `process.pid` (+ its ancestors from the scan's proc table).

## App surface

- `store/ports.dart`: a `killPort(PortKillTarget) → Future<PortKillOutcome>` sender using the
  socket's **request** path (unlike `ports.watch`'s fire-and-forget `send` — the caller needs the
  outcome), plus a `PortKillOutcome` mirror enum decoded tolerantly (an unknown string ⇒ treated as
  a failure the UI reports generically, never as success).
- **Desktop** (`ports_popover.dart`): the `Kill` action is the **last** button in each port row's
  action group, `cs.error`-tinted, still gated by the confirm even when the popover is pinned. On
  `identity_mismatch`/`not_found` the popover surfaces "that changed — rescan"; on `survived`, "still
  running — open a terminal".
- **Mobile** (`port_detail_sheet.dart`): a `Kill this process…` row **appended past a `danger`
  divider as the sheet's last row** (the `dangerzone`/`dz-lbl` treatment in §2b). Sheet 1
  (`worktree_ports_sheet.dart`) stays button-free (§10).
- **Confirm (both):** `AlertDialog`, title `Kill :<port>?`, body naming command + pid + port +
  worktree, e.g. *"Sends SIGTERM (then SIGKILL if it ignores it) to `vite` (pid 48211) serving
  :5173 in feat/open-ports."* Destructive button `cs.error`. The `{address, port, pid, startedAt}`
  the dialog names is exactly what the command carries (D1/D8).

## Tests

| Layer | Test | Mutation that proves it bites |
| --- | --- | --- |
| `ports/kill.test.ts` (pure `classifyKillTarget`) | the full R1–R7 refusal table: `scan_unavailable`, `not_found`, `identity_mismatch` (recycled pid; restarted `startedAt`), `not_owned`, `refused_protected`, `refused_self` (server pid + ancestor), `refused_session`; and a **positive** case — a worktree-owned matched tuple returns `{signal:true}` | see the per-row mutations in the D3 table (each refusal row) |
| `ports/kill.test.ts` (orchestrator `killPort`, injected `exec`/`signal`/`sleep`/clock) | SIGTERM then endpoint free → `released`, **no** SIGKILL; SIGTERM ignored → SIGKILL → gone → `force-killed`; SIGKILL and still listening → `survived`; `signal` throws `ESRCH` after SIGTERM → `released`; **grace-window pid churn** (pid exits + is reused during `KILL_GRACE_MS`) → **no SIGKILL to the recycled pid** (R8); a releasing outcome requests exactly one immediate re-scan, a refusal requests none | remove the pre-SIGKILL re-verify (R8); escalate unconditionally (drop the "still matched" check) so a `released` process gets a spurious SIGKILL |
| `ws/commands/ports.test.ts` | `ports.kill` with a valid tuple acks a `PortKillResult`; a missing/`NaN` `pid`/`startedAt`/`port`/`address` ⇒ `err bad_request` and **`killPort` is never called**; a refusal outcome still **acks** (never `err`); a releasing outcome triggers the immediate broadcast | coerce a malformed tuple to defaults and call `killPort` anyway; convert a refusal outcome into an `err` frame |
| `ws/commands/ports.test.ts` (auth/dev-mode) | an **unauthed** client's `ports.kill` never reaches the handler (dispatch is gated on `client.authed`); under `trustLocalhost` a **loopback** client is `authed` and may kill (D4) — asserted, not assumed | flip the dispatch gate so an unauthed frame dispatches |
| `store/ports_test.dart` | `killPort` sends `{kind:'ports.kill', address, port, pid, startedAt}` via `request`; each `PortKillOutcome` decodes; an unknown outcome string decodes to the generic-failure value, **never** to a success | decode an unknown string as `released` |
| `ui/ports/ports_popover_test.dart` | `Kill` is the **last** action, `cs.error`-tinted; tapping it opens a confirm **naming the pid and port**; dismissing the confirm sends **nothing**; confirming sends the exact displayed tuple; a pinned popover still confirms | render `Kill` without a confirm (call `killPort` straight from `onTap`) |
| `ui/ports/ports_sheets_test.dart` | sheet 1 has **no** kill control; sheet 2's `Kill…` is the **last** row, past the `danger` divider; it confirms naming pid+port; `startedAt`-absent ports **omit** `Kill` (unverifiable per D1) | move `Kill` into sheet 1 / into the scrollable list; offer `Kill` on a `startedAt`-less port |
| `integration_test/stub/ports_kill_test.dart` | full stack against the stub server: snapshot → open detail → confirm → ack `released` → the endpoint vanishes on the next snapshot | — |
| `ports/kill_acceptance.test.ts` | **real-machine proof:** temp git worktree + a real `node` listener with its `cwd` in it → real scan → `killPort` the real tuple → the port is gone and a **second** `killPort` returns `not_found`. `test.skip` with a printed reason where `lsof` is unavailable (Linux CI parity, per SPEC-41 T9) | — |

P3b (`ports.killOrphans`) tests are written but gated on SPEC-42's orphan source; until it lands the
orphan set is empty, `killOrphans` returns `{results: []}`, and the `Kill all orphans` button does
not render.

## Verification (beyond unit tests — per `makit-verify-feature-end-to-end`)

1. `cd server && node_modules/.bin/tsc -p . --noEmit && pnpm test`
2. `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub`
3. `ports/kill_acceptance.test.ts` — the scripted real-listener-in-a-real-worktree kill, on macOS
   **and** Linux (the two emit different `lsof -F` records; the SPEC-41 T9 lesson).
4. A live eyeball: start a real `vite` in a worktree, kill it from the app, confirm the process is
   gone (`lsof -nP -iTCP -sTCP:LISTEN`) **and** that killing a system listener (e.g. `:22`) is
   refused with `not_owned`, and that killing makit's own `:9787` is refused with `refused_self`.
5. Keyless loop (no simulator): `pnpm exec tsx test/e2e-server.ts --mode stub --project <path>`
   driven by a WSS client — `{t:"hello",bearer}` → `ports.watch {on:true}` → `ports.kill` — asserts
   the ack outcome and the follow-up snapshot.
