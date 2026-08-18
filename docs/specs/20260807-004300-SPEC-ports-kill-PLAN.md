# SPEC-ports-kill — Implementation plan (P3a, single-port kill)

Spec: [`20260807-004300-SPEC-ports-kill.md`](./20260807-004300-SPEC-ports-kill.md) ·
Mockups: [`mockups/open-ports.html`](../../mockups/open-ports.html)

Ground rules (AGENTS.md): **failing test first**, SOLID/YAGNI, surgical diffs, match existing
style. Commands are the repo-supported ones from [`docs/DEVELOPMENT.md`](../DEVELOPMENT.md) —
`pnpm test` / `pnpm typecheck` in `server/`, `flutter test --no-pub` /
`flutter analyze --fatal-infos --no-pub` in `app/`. Two caveats that cost real time: never
`pnpm exec tsx --test` (it prunes devDependencies and hangs — use `pnpm test`, or
`node --import tsx --test <file>` for one file), and where `flutter` is not on `PATH` use the
absolute binary (AGENTS.md records `~/flutter/bin/flutter` on the Linux VM).

D1–D8 in the spec are **locked**; there is no decision gate left in this plan.

**Scope: P3a only.** P3b (`ports.killOrphans` + the `Kill all orphans` button) and the suggested
free port (D6) do **not** ship here — P3b hard-depends on SPEC-ports-global-view's orphan set (D5), D6 moved to
SPEC-ports-global-view. P3a is independently shippable.

## Order (contract-first, purest-first)

The pure whitelist classifier is written **first** so there is a red test asserting every refusal
*before* any code can signal a process. The orchestrator (which owns the only `process.kill` call)
comes second, behind the classifier. The wire handler and app come after the shape is frozen.

```
T1 protocol tuple + PortKillOutcome (frozen shape, red on the pure classifier)
   └─ server ─▶ T2 classifyKillTarget (pure, refusal table)
                   └─▶ T3 PortsService.killPort (signal + grace + escalate, injected)
                          └─▶ T4 ws/commands/ports.ts `ports.kill` + deps + server wiring
                                 └─▶ T5 ports/kill_acceptance.test.ts (real listener)
   └─ app ─────▶ T6 store/ports.dart killPort + PortKillOutcome mirror
                   ├─▶ T7 desktop popover Kill (last, red-wash, confirm)
                   └─▶ T8 mobile sheet-2 Kill (past danger divider, confirm)
                          └─▶ T9 e2e + docs
```

Each task states its **red test** and its **verify** command. A task is not done until its verify
command passes and the whole suite still does.

---

## T1 · protocol shape + `PortKillOutcome`

Red: extend `server/test/ws/commands/ports.test.ts` (or a new `ports/kill.test.ts` for the pure
part in T2) to reference `PortKillTarget`/`PortKillResult`/`PortKillOutcome` — fails to compile
before the types exist.

Green: `protocol.ts` — add `PortKillTarget`, `PortKillOutcome`, `PortKillResult`,
`PortKillOrphansResult` (P3b type declared now so the union is stable, unused until SPEC-ports-global-view);
`CmdKind` += `"ports.kill"` and `"ports.killOrphans"` **with the P3b/SPEC-ports-global-view comment** so the next
contributor does not wire the orphan command before its dependency exists. `startedAt` is
**required** on `PortKillTarget` (D1) even though optional on `PortDTO`. **No `EventKind` change**
— the outcome rides the ack, the refresh rides the existing `ports.snapshot`; leave the
`SessionEventKind`/`HOST_ONLY_KINDS` carve-out untouched.

Verify: `cd server && node_modules/.bin/tsc -p . --noEmit`.

## T2 · `ports/kill.ts` — `classifyKillTarget` (pure, no I/O)

Red: `server/test/ports/kill.test.ts` — the full R1–R7 refusal table from the spec, fed a literal
fresh `PortDTO[]` + `{serverPid, serverAncestors, sessionRoots}`:

- `scan_unavailable` when handed a failed scan (R1);
- `not_found` when no `(address,port)` match (R2);
- `identity_mismatch` on a pid mismatch **and** on a `startedAt` mismatch at the same endpoint (R3);
- `not_owned` for a matched pid with no `worktreePath` (R4);
- `refused_protected` for pid 1 (R5);
- `refused_self` for the server pid **and** for an ancestor pid (R6);
- `refused_session` for a pid in `sessionRoots` (R7);
- a **positive**: a worktree-owned, identity-matched tuple → `{signal:true, pid}`.

Each assertion must also prove the classifier **returned no signal** on every refusal (it is pure,
so "no signal" = `signal:false`).

Green: `classifyKillTarget(target, freshScan, guards)` → `{signal:true, pid} | {signal:false,
outcome}`. Rules evaluated in the R1→R7 order. No imports of `child_process`; this function
**cannot** signal.

Verify: `pnpm test -- --test-name-pattern=kill` (or `node --import tsx --test test/ports/kill.test.ts`).

## T3 · `PortsService.killPort` — orchestration (the only `process.kill`)

Red: extend `ports/kill.test.ts` (or `ports/service.test.ts`) with an orchestrator suite using an
injected literal `exec`, an injected `signal` spy, an injected `sleep`, and the fake clock the
service tests already use:

- SIGTERM then the endpoint is free on re-scan → `released`, **SIGKILL never sent**;
- SIGTERM ignored (still listening) → SIGKILL → gone → `force-killed`;
- SIGKILL sent and still listening → `survived`;
- `signal` throws `ESRCH` after SIGTERM → `released`; throws `EPERM` → `survived`;
- **R8 grace-window churn:** during `KILL_GRACE_MS` the target pid exits and `(address,port)` is
  re-bound by a **different** pid/`startedAt` → **no SIGKILL to the recycled pid**, outcome
  `released`;
- R1 short-circuit: the fresh scan resolves `{ok:false}` → `scan_unavailable`, **`signal` never
  called**;
- a releasing outcome invokes the injected `requestImmediateScan` exactly once; a refusal invokes
  it zero times.

Green: add to `PortsServiceDeps` — `signal?: (pid, sig) => void` (default `process.kill`),
`sleep?: (ms) => Promise<void>` (default `setTimeout`-backed). `killPort(target)` runs a fresh
scan (reusing the private scan path — factor the three-read+attribute body so both `doScan` and
`killPort` call it, no duplication), computes `serverAncestors` by walking `process.pid`'s `ppid`
chain in the fresh proc table via `ancestors.ts`'s `walkAncestors`, calls `classifyKillTarget`,
and on `{signal:true}` runs the SIGTERM→grace→re-verify→SIGKILL→re-verify ladder. Every `signal`
call is wrapped for `ESRCH`/`EPERM` (D2). `KILL_GRACE_MS` = `2_000`, named here with the comment.
`serverPid`/`sessionRoots` come from injected providers (the service already has
`listSessionRoots`; add `serverPid: () => number` defaulting to `() => process.pid`).

Verify: `pnpm test -- --test-name-pattern=kill`, then `pnpm test` (whole suite) + `tsc --noEmit`.

## T4 · `ws/commands/ports.ts` `ports.kill` handler + deps + `server.ts` wiring

Red: `server/test/ws/commands/ports.test.ts` —

- a valid tuple acks a `PortKillResult` (stub `deps.killPort` returns `released`);
- a missing / non-numeric `pid`/`startedAt`/`port` or non-string `address` ⇒ `err bad_request`
  and **`killPort` is never called**;
- a refusal outcome (`identity_mismatch`) still **acks** (never `err`);
- a releasing outcome triggers the immediate `ports.snapshot` broadcast; a refusal does not;
- **auth:** an unauthed client's frame never dispatches (assert against the `client.authed` gate);
  under `trustLocalhost` a loopback client is `authed` and reaches the handler (D4).

Green: register `ports.kill` in `ws/commands/ports.ts` beside `ports.watch` — parse+validate the
four fields (the `metrics.watch`/`ports.watch` malformed-payload discipline: reject, do not
coerce), `ctx.ack(await deps.killPort(target))`, and on a releasing outcome call the deps hook that
asks `portsService` for one immediate scan+broadcast. `CommandDeps` (`ws/commands/deps.ts`) grows
`killPort(target): Promise<PortKillResult>` — **required**, per SPEC-open-ports deviation #2's lesson (an
optional dep that silently no-ops is worse than a compile error); update the fakes. `server.ts`
wires `killPort` to `portsService.killPort` with `serverPid`/`listSessionRoots` already available,
and adds the immediate-rescan hook (reuse the 0→1 immediate-scan path).

Verify: `pnpm test` + `node_modules/.bin/tsc -p . --noEmit`.

## T5 · `ports/kill_acceptance.test.ts` — the real-machine proof

Red-by-construction (mirrors SPEC-open-ports `ports/acceptance.test.ts`): create a temp git repo + worktree,
spawn a real `node` HTTP listener with `cwd` set to it, run the **real** `PortsService.killPort` with
the real scanned tuple, assert the port is gone and a **second** `killPort` returns `not_found`; kill
the listener in `finally` (cleanup must never throw and mask the original error — the SPEC-open-ports lesson).
`test.skip` with a printed reason when `lsof` is missing (Linux CI).

This catches what a fixture cannot: a wrong fresh-scan attribution, a signal that misses, or an
escalation ladder that reports success while the process lives.

Verify: `pnpm test -- --test-name-pattern=kill_acceptance` on macOS **and** Linux.

## T6 · `store/ports.dart` — `killPort` sender + `PortKillOutcome` mirror

Red: `app/test/store/ports_test.dart` — `killPort(target)` sends
`{kind:'ports.kill', address, port, pid, startedAt}` over the **request** path (captured via an
injected sender, like the `PortsWatch` test); each `PortKillOutcome` string decodes to its enum;
an **unknown** outcome string decodes to a generic-failure value, never to a success.

Green: a `PortKillOutcome` enum mirror + tolerant parse, and a `killPort` method on the ports store
that uses `conn.request` (not `send` — the caller needs the ack). Fire-and-forget `ports.watch`
stays `send`; only kill uses `request`.

Verify: `flutter test --no-pub test/store/ports_test.dart`.

## T7 · desktop popover `Kill` (last, red-wash, confirm)

Red: `app/test/ui/ports/ports_popover_test.dart` — `Kill` is the **last** action and `cs.error`-
tinted; tapping opens a confirm **naming pid + port**; dismissing sends **nothing**; confirming
calls `killPort` with the exact displayed `{address, port, pid, startedAt}`; a pinned popover still
confirms; a port whose `startedAt` is absent shows **no** `Kill` (unverifiable, D1). (Any
`Clipboard` assertions install a `SystemChannels.platform` mock — an un-mocked call *hangs*, the
SPEC-open-ports project-skill trap.)

Green: add the `Kill` action to `ports_popover.dart` (last in the row's action group, red-wash),
an `AlertDialog` confirm helper naming the target (the `worktree_actions`/`session_tile` shape),
and outcome handling (`identity_mismatch`/`not_found` → "rescan"; `survived` → "open a terminal").

Verify: `flutter test --no-pub test/ui/ports/ports_popover_test.dart` + `flutter analyze --fatal-infos --no-pub`.

## T8 · mobile sheet-2 `Kill` (past the danger divider, confirm)

Red: `app/test/ui/ports/ports_sheets_test.dart` — sheet 1 still has **no** kill control; sheet 2's
`Kill this process…` is the **last** row, past a labelled `danger` divider; tapping it confirms
naming pid + port; a `startedAt`-absent port omits the row. Confirm-dismiss sends nothing.

Green: append the danger zone to `port_detail_sheet.dart` (the `dangerzone`/`dz-lbl`/`arow danger`
treatment from §2b) as the sheet's last content, with the same confirm helper as T7. `worktree_ports_sheet.dart`
is untouched (§10: no actionable control reachable from a flick).

Verify: `flutter test --no-pub test/ui/ports/ports_sheets_test.dart`.

## T9 · e2e + docs

- `integration_test/stub/ports_kill_test.dart`, registered in `all_stub_test.dart`: snapshot → open
  detail → confirm → ack `released` → the endpoint vanishes on the next snapshot.
- `test/e2e-server.ts`: teach the stub to answer `ports.kill` deterministically (a fixed outcome
  for the seeded port) so the keyless loop exercises the real ack path.
- `docs/UX.md`: one paragraph — where `Kill` lives on each platform, that it confirms and names the
  target, and that it can refuse (pid changed / not owned / still running).

Verify: `tool/e2e.sh --mode=stub` on macOS (needs a simulator); elsewhere the keyless server loop
(`pnpm exec tsx test/e2e-server.ts --mode stub --project <path>` driven by a WSS client).

---

## Definition of done

1. `cd server && pnpm typecheck && pnpm test` green.
2. `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub` green.
3. `ports/kill_acceptance.test.ts` green with the real `lsof`/`ps` — on macOS **and** Linux.
4. A test proves **no `signal` is called on any refusal** (R1–R7) and **no SIGKILL** is sent when
   the process released after SIGTERM or when the grace-window identity changed (R8) — asserted via
   the injected `signal` spy, not inspected.
5. A test proves an **unauthed** `ports.kill` never dispatches, and that `trustLocalhost` loopback
   may kill (D4).
6. `tool/e2e.sh --mode=stub` green with `ports_kill_test` listed — macOS only (needs a simulator).
7. `dart format lib test tool integration_test` clean (**not** `dart format .` — it walks `build/`,
   where cargokit writes unformatted generated Dart; project skill).

## Deviations log

Record every departure from this plan here as it happens, with the reason (the convention
SPEC-message-navigator-PLAN uses). Empty at the start.

| # | Task | Deviation | Why |
| --- | --- | --- | --- |
| — | — | — | — |

## Risks

| Risk | Mitigation |
| --- | --- |
| A pid is reused between the client's snapshot and the signal (the core hazard). | D1: the server ignores its cache, re-scans, and re-matches all four of `{address, port, pid, startedAt}`; the `wrap_up.dart` `expectBranch` + `daemon/service.ts` reuse-guard precedents. Proved by the R3 test and the R8 grace-window-churn test. |
| The escalation ladder redirects a SIGKILL onto a recycled pid during the grace window. | D2 re-runs D1 before the SIGKILL; R8 test asserts no SIGKILL to a changed identity. |
| `ports.kill` becomes the first path that signals a non-child pid, widening the attack surface. | D3 whitelist confines it to worktree-owned dev servers (blast radius = `worktree.remove`); R4–R7 refuse system/self/ancestor/session/pid-1; D4 justifies bearer-sufficiency against `send.message`'s existing RCE. |
| `--no-auth`/`trustLocalhost` silently permits kill to any loopback client. | D4 decides this **on purpose** (loopback = local user = already has `kill(1)`) and the T4 auth test pins it, so it is a recorded decision, not an accidental hole. |
| `git.ts`'s `run()`/`listListeners` never reject — a failed `lsof` looks like an empty machine. | R1: the kill path refuses (`scan_unavailable`) on `{ok:false}` instead of "no listener ⇒ nothing to kill ⇒ success"; the T2/T3 tests inject a spawn fault. |
| `process.kill` throws (`ESRCH`/`EPERM`) out of the orchestrator. | Every `signal` call is wrapped; `ESRCH`⇒`released`, `EPERM`⇒`survived` (D2), covered by T3. |
| A phone user kills the wrong thing by fat-fingering a list. | §10 + D8: no inline kill in the scrollable list; `Kill` is the last row of sheet 2 behind the `danger` divider and a confirm that names the victim. |
| Kill-all-orphans ships before SPEC-ports-global-view can define "orphan". | D5: `ports.killOrphans` is declared but inert (empty orphan set) until SPEC-ports-global-view; the button does not render; P3a stands alone. |
