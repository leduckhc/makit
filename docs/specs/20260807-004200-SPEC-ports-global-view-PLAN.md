# SPEC-ports-global-view — Implementation plan (P2)

Spec: [`20260807-004200-SPEC-ports-global-view.md`](./20260807-004200-SPEC-ports-global-view.md) ·
Mockups: [`mockups/open-ports.html`](../../mockups/open-ports.html) (§5–§7, §9)

Ground rules (AGENTS.md): **failing test first**, SOLID/YAGNI, surgical diffs, match existing
style. Commands are the repo-supported ones from
[`docs/DEVELOPMENT.md`](../DEVELOPMENT.md): `pnpm test` / `pnpm typecheck` in `server/`,
`flutter test --no-pub` / `flutter analyze --fatal-infos --no-pub` in `app/`. Two caveats that
cost real time: never `pnpm exec tsx --test` (prunes devDependencies and hangs — use
`pnpm test`, or `node --import tsx --test <file>` for one file); and where `flutter` is not on
`PATH` use the absolute binary (AGENTS.md records `~/flutter/bin/flutter` for the Linux VM).

D8–D16 in the spec are **locked**; there is no decision gate in this plan.
**P2 sends no signal to any process** — every kill affordance is P3.

## Sub-phase order (each ships alone — D16)

The three sub-phases are landable independently and in this order. **P2a touches no protocol
and no scan**, so it can merge first with zero wire risk. **P2b** adds the history store and
optional wire fields; its contract golden goes red first, before any server code. **P2c**
(docker + menubar) is independent of P2b.

```
P2a  app-only, existing snapshot
  T1 routes+screen scaffold ─▶ T2 filter/group (pure) ─▶ T3 PortsScreen widget
  T4 ⌘⇧P action  ─┐
  T5 overflow item ┼─▶ (all navigate to kRoutePorts)
  T6 session glyph ┘
  T7 mobile "Open the Ports screen" button

P2b  history + protocol   (depends on P2a screen for the orphans section UI)
  T8 protocol + RED contract golden ─▶ T9 history_store ─▶ T10 derive (pure)
     ─▶ T11 service wiring ─▶ T12 app parse + Orphans filter/section + collision banner

P2c  docker + menubar      (independent of P2b)
  T13 protocol field + RED contract golden ─▶ T14 docker.ts ─▶ T15 service overlay
  T16 menubar Ports submenu

T17 e2e + docs
```

Each task states its **red test** and its **verify** command. A task is not done until its
verify passes and the whole suite still does.

---

## P2a — the global screen and its entry points (no protocol, no scan)

### T1 · `kRoutePorts` + the screen scaffold

Red: `test/app/router_ports_test.dart` — navigating to `kRoutePorts` builds a `PortsScreen`
with an `AppBar` titled "Ports"; `?repo=<id>` is readable by the screen. Fails: neither the
route nor the widget exists.

Green: `routes.dart` `const kRoutePorts = '$kRouteRepos/ports';` + optional `?repo=`
convention; `router.dart` a `GoRoute(path:'ports', builder: … PortsScreen(repoId: …))` beside
`archived`; a minimal `ui/ports/ports_screen.dart` (`ConsumerStatefulWidget`, `Scaffold` +
`AppBar` with a back leading, mirroring `ArchivedScreen`). Hold the ports watch in
`initState`/`dispose` via `portsWatchProvider` (the ref-counted P1 gate).

Verify: `flutter test --no-pub test/app/router_ports_test.dart`.

### T2 · `ui/ports/ports_filter.dart` — pure filter + grouping *(before the widget)*

Red: `test/ui/ports/ports_filter_test.dart` — the full table from the spec's Tests section:
*All* keeps everything; *This repo* keeps one repo's owned ports; *Mine* keeps ports with a
`worktreePath`; *Exposed* keeps `reach == exposed`; grouping is repo → worktree → port in
first-seen order; unowned → an "other / system" group. Pure functions, no widgets, no
container.

Green: `PortsFilter` enum (`all`, `thisRepo`, `mine`, `exposed` — **not** `orphans` yet, that
is T12) + `filterPorts(snapshot, filter, {repoId})` + `groupByRepoWorktree(ports, repos)`.
The repo/worktree lookup reads `ReposState` the way `archived_screen.dart` does.

Verify: `flutter test --no-pub test/ui/ports/ports_filter_test.dart`.

### T3 · `PortsScreen` widget

Red: `test/ui/ports/ports_screen_test.dart` — chips switch the visible set; zero ports → the
empty state; `scanOk:false` → the degraded banner (not an empty list — the D7/`unknown`
honesty); unowned-only → the system group; tapping a port opens the P1 `port_detail_sheet`;
the watch ref-count returns to 0 on dispose.

Green: flesh out `PortsScreen` — the filter row (`archived_screen` chip styling), the grouped
`ListView` (reuse `_GroupHeader` shape), the P1 detail sheet on tap. Renders
`ref.watch(portsProvider)` through T2's pure functions.

Verify: `flutter test --no-pub test/ui/ports/` + `flutter analyze --fatal-infos --no-pub`.

### T4 · `ShortcutAction.openPorts` = `⌘⇧P` (D9)

Red: extend `test/shortcuts/keymap_test.dart` — `openPorts` defaults to `⌘⇧P` (meta) /
`⌃⇧P` off-mac; `conflictFor` finds **no** conflict in `ShortcutScope.global`. Fails: the enum
value does not exist.

Green: add `openPorts` to `shortcut_action.dart` (global scope, stable `id:'openPorts'`, label
"Open Ports"); add the default to `keymap.dart` (`primary(LogicalKeyboardKey.keyP, shift:true)`);
wire the `Intent` in `desktop/chat/keymap_scope.dart` to `context.go(kRoutePorts)`.

Verify: `flutter test --no-pub test/shortcuts/ test/desktop/chat/` + analyze.

### T5 · `Ports (n)…` in the worktree overflow menu (D8)

Red: `test/desktop/chat/desktop_sidebar_ports_menu_test.dart` — `_WorktreeMenuButton` shows a
`Ports (n)…` item with the worktree's port count (from `portsForWorktreeProvider`); selecting
`value:'ports'` calls `onSelected('ports')`, which the group state routes to `kRoutePorts`
with the repo pre-filter. The item is present regardless of the `_portsOpen`/hover latch.

Green: one `PopupMenuItem(value:'ports')` in `_WorktreeMenuButton.itemBuilder` (count from a
watched provider), plus a `'ports'` arm in `_WorktreeGroupState`'s `onSelected` that calls
`context.go('$kRoutePorts?repo=${repo.id}')`. **No popover controller is lifted** (D8).

Verify: `flutter test --no-pub test/desktop/chat/desktop_sidebar_ports_menu_test.dart`.

### T6 · session-tile glyph (D14)

Red: `test/ui/ports/session_ports_glyph_test.dart` — renders nothing when no port has this
`sessionId`; renders quietly (**no attention dot**) when one does; semantics label names the
port; tapping opens the worktree ports surface.

Green: `ui/ports/session_ports_glyph.dart` — a `ConsumerWidget` reading a new pure selector
`portsForSession(snapshot, sessionId)`; mount it on the desktop `_SessionTile` and the mobile
session tile as a trailing element, guarded to render nothing when empty. Reuse `PortsGlyph`
with the attention dot suppressed.

Verify: `flutter test --no-pub test/ui/ports/session_ports_glyph_test.dart` + analyze.

### T7 · mobile "Open the Ports screen" button + home entry

Red: extend `test/ui/ports/ports_sheets_test.dart` — sheet 1 has an "Open the Ports screen"
button that navigates to `kRoutePorts`; a home app-bar test asserts the plug icon navigates
there (mirroring the Archived icon).

Green: add the button to `worktree_ports_sheet.dart`; add a plug `IconButton` to
`home_screen.dart`'s app bar → `context.go(kRoutePorts)`.

Verify: `flutter test --no-pub test/ui/ports/ports_sheets_test.dart test/ui/home/` + analyze.
**P2a ships here** — `flutter analyze --fatal-infos --no-pub && flutter test --no-pub` green,
no server change.

---

## P2b — port history, orphans, collisions (protocol + server + app)

### T8 · protocol + the red contract golden *(contract red first)*

Red: add a `ports.snapshot` envelope carrying a port with `orphan` and one with `collision` to
`server/test/fixtures/snapshots.json`; extend `protocol/contract.test.ts` with the
`decodeFrame` round-trip **and** `assert.equal(decodeSessionEvent(thatEnvelope), null)` (the
reused `HOST_ONLY_KINDS` half — no new event kind is added, so this proves the optional fields
did not accidentally change the carve-out). Both fail before the code.

Green: `protocol.ts` — add `PortOrphanDTO`, `PortCollisionDTO` and the optional
`PortDTO.orphan` / `PortDTO.collision`. **No** `EventKind` / `SessionEventKind` / `CmdKind`
change (the event already exists). Add the Dart half in T12.

Verify: `cd server && pnpm test -- --test-name-pattern=contract && node_modules/.bin/tsc -p . --noEmit`.

### T9 · `ports/history_store.ts`

Red: `server/test/ports/history_store.test.ts` — missing file → `{entries:[]}`; corrupt JSON →
`{entries:[]}` (no throw); `MAKIT_PORT_HISTORY_FILE` override honoured; `upsertEntry` adds a
port + bumps `lastSeen`; entries past `HISTORY_TTL_MS` dropped on save; a write failure is
swallowed. These mirror `project-store.test.ts` one-for-one.

Green: `loadHistory` / `saveHistory` / `historyFile` / `upsert` following `project-store.ts`
exactly (try/catch → empty, `mkdirSync` + pretty JSON, `log.warn` + swallow). `HISTORY_TTL_MS`
and the per-entry port cap are named constants.

Verify: `cd server && pnpm test -- --test-name-pattern=history`.

### T10 · `ports/derive.ts` — pure orphan/collision

Red: `server/test/ports/derive.test.ts` — the D10/D12 table: unowned port whose cwd matches a
*removed* history path → `orphan` with branch + date; **empty history → no orphan, no
fabricated date**; system port matching nothing stays plain unowned; owned port with a second
active worktree in history → `collision.withBranch`; single-owner port → no collision; inputs
never mutated; never throws.

Green: `annotate({ports, cwds, procs, history, activeWorktreePaths, resolveReal, now})` →
`PortDTO[]`. Reuse `walkAncestors`, `segments`, `isSegmentPrefix` from the ports module (import
the pure helpers; do **not** edit `attribute.ts`). Pure.

Verify: `cd server && pnpm test -- --test-name-pattern=derive`.

### T11 · `service.ts` wiring (history upsert → annotate)

Red: extend `server/test/ports/service.test.ts` — after a scan with an owned port, the injected
history sink received an upsert; a rescan after that worktree leaves `activeWorktreePaths`
yields an orphan-annotated snapshot; the history write is **debounced** (identical projection →
no second write); a throwing history read keeps the scan alive (`scanOk` still reflects the
scan, not the store).

Green: in `doScan`, after `attribute(...)`: `upsert` owned ports into an injected history
handle, then `annotate(...)` before publishing. History load/save are injected deps (like
`exec`) so tests use an in-memory fake — `server.ts` wires the real `history_store` file
functions. The debounce reuses the existing projection compare.

Verify: `cd server && pnpm test` (whole suite) + `tsc --noEmit`.

### T12 · app: parse + Orphans filter + orphans section + collision banner

Red: extend `test/store/ports_test.dart` (tolerant `orphan`/`collision` parse — malformed
sub-object → null, port kept) and `test/ui/ports/ports_screen_test.dart` (the *Orphans* filter
appears and shows the orphans section; "Kill all orphans" is **absent** — P3; the collision
banner names the other branch with **no** `PORT=` suggestion — D12); `codec_contract_test.dart`
reads the T8 fixture.

Green: `store/ports.dart` — `PortOrphan`/`PortCollision` models + tolerant `fromJson`; add
`PortsFilter.orphans` to `ports_filter.dart`; render the orphans group (with the D10 date-or-
cwd rule) and the collision banner in `PortsScreen`. No kill control.

Verify: `flutter test --no-pub test/store/ test/ui/ports/ test/codec_contract_test.dart` +
analyze. **P2b ships here.**

---

## P2c — docker attribution + menubar (independent of P2b)

### T13 · protocol `PortDTO.docker` + red contract golden

Red: extend `snapshots.json` with a docker-annotated port and `contract.test.ts` with its
round-trip (+ the unchanged `decodeSessionEvent` rejection). Fails before the field exists.

Green: `protocol.ts` — `PortDockerDTO` + optional `PortDTO.docker`. Dart parse in T15's app
touch is covered by `ports_test.dart`.

Verify: `cd server && pnpm test -- --test-name-pattern=contract && tsc --noEmit`.

### T14 · `ports/docker.ts` — code-checked `docker ps`

Red: `server/test/ports/docker.test.ts` — `code !== 0` → `{ok:false}`, no annotation, no throw
(**the `git.ts run()` 127 trap** — a missing binary must not read as "no containers"); a
`0.0.0.0:5432->5432/tcp` publish map parses to `{5432 → {container}}`; compose path from the
label when present, absent otherwise; TTL cache reuses within `DOCKER_TTL_MS`, re-reads after.

Green: `readDockerPorts(exec, timeoutMs)` running
`docker ps --format '{{.Names}}\t{{.Ports}}\t{{.Label "…config_files"}}'`, checking `code`
explicitly, parsing publish maps, TTL-cached. `DOCKER_TTL_MS` named.

Verify: `cd server && pnpm test -- --test-name-pattern=docker`.

### T15 · `service.ts` docker overlay

Red: extend `service.test.ts` — a docker-backend listener on a published host port gains
`docker`; a no-docker machine (`code:127`) yields a normal snapshot with no docker fields and
no repeat cost after the first probe; `reach` is unchanged (D13).

Green: in `doScan`, overlay `readDockerPorts` results (matched by host port) onto listeners
whose process is the docker backend, **after** attribution/derivation, only while watched.
`server.ts` injects the docker reader.

Verify: `cd server && pnpm test` + `tsc --noEmit`.

### T16 · menubar `Ports (n)` submenu (D15)

Red: extend `test/desktop/tray/tray_controller_test.dart` — the `Ports (n)` submenu lists
cached ports; "Open Ports…" present; **no** `Kill` items; no snapshot → "No ports"; the
controller triggers **no** scan.

Green: extend `DaemonSummary` with an optional cached port list + attention count; add
`_dynamicPortsSubmenu` mirroring `_dynamicDeviceSubmenu`/`_dynamicSessionSubmenu`; add "Open
Ports…". The count feeds the tooltip. The desktop shell supplies the cached snapshot it already
holds (no new watch — D15).

Verify: `flutter test --no-pub test/desktop/tray/` + analyze.

---

## T17 · e2e + docs

- `test/e2e-server.ts`: publish a snapshot with one orphan and one collision (P2b) and, where a
  docker fixture is convenient, one docker port (P2c), so the screen exercises the real frame.
- `integration_test/stub/ports_test.dart` (extend, registered in `all_stub_test.dart`): open
  the global screen, switch to *Orphans*, assert the orphans section.
- `docs/UX.md`: one paragraph — the global screen, its filters, the orphans read, and the
  menubar entry.

Verify: `tool/e2e.sh --mode=stub` **on macOS**; where no simulator exists, the keyless server
loop is the substitute (`pnpm exec tsx test/e2e-server.ts --mode stub --project <path>` driven
by a WSS client: `{t:"hello",bearer}` → `sub` → `ports.watch`).

---

## Definition of done

1. `cd server && pnpm typecheck && pnpm test` green.
2. `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub` green.
3. `derive.test.ts` proves D10: an orphan with recorded history shows a real date; with the
   history file deleted, the same orphan shows cwd and **no** date — asserted, not inspected.
4. `docker.test.ts` proves the 127 trap: a non-zero `docker ps` exit produces **no** docker
   annotation, never an empty-but-successful read.
5. `contract.test.ts` still rejects `ports.snapshot` in `decodeSessionEvent` after the optional
   fields are added (the `HOST_ONLY_KINDS` half is untouched).
6. `tool/e2e.sh --mode=stub` green with the P2 cases listed — macOS only (needs a simulator).
7. `dart format lib test tool integration_test` clean (**not** `dart format .` — it walks
   `build/`, where cargokit writes unformatted generated Dart; project skill).

## Deviations log

Record every departure from this plan here as it happens, with the reason — the convention
SPEC-message-navigator/41-PLAN uses. Empty at the start.

| # | Task | Deviation | Why |
| --- | --- | --- | --- |

## Risks

| Risk | Mitigation |
| --- | --- |
| **Collision (D12) reads as wrong** — the OS forbids two live `LISTEN`s on one endpoint, so the second worktree's clash is entirely history-derived and can surprise a user whose history is stale | Conservative definition (≥2 *still-active* worktrees in history), no suggested port (P3), and the whole feature sits behind the P2b history store so it can be tuned or reverted without touching P2a; named as the spec's single riskiest decision |
| Orphan fabricates a date on thin history | D10 + `derive.test.ts` empty-history case: `removedAt`/`formerBranch` are omitted, never zeroed; the UI renders cwd only |
| `docker ps` hangs when the daemon is wedged | bounded by the existing `EXEC_TIMEOUT_MS`, TTL-cached so it runs at most once per ~10 s, watch-gated, and code-checked so a dead daemon degrades to unowned (P1 behaviour) |
| History JSON corrupts and blocks startup | `loadHistory` never throws → `{entries:[]}`, exactly `project-store.ts`; the server always starts |
| Menubar tempts an always-on watch | D15: the tray renders the app's cached snapshot and never arms the scanner; asserted by the "no scan triggered" tray test |
| Optional wire fields silently break the P1 carve-out | contract test re-asserts `decodeSessionEvent` rejection after every field addition (T8, T13) |
