# SPEC-42 — Ports P2: the global view, orphans, docker, the menubar

**Status:** Draft · **Priority:** P2 · **Branch:** `feat/open-ports-fixup`
**Depends on:** SPEC-41 (ports P1 — scan, attribution, health, `ports.snapshot`, the row glyph,
the desktop popover, the two mobile sheets), SPEC-11 (repo-centric home), SPEC-19
(`ws/commands/*` split), SPEC-29 (`archived_screen.dart` — the new-destination precedent),
SPEC-37 (host-wide broadcast + tree walk)
**Mockups:** [`mockups/open-ports.html`](../../mockups/open-ports.html) — §5 (overflow item),
§6 (global screen), §7 (menubar), §9 (semantics legend), §10 (rejected)

---

## Goal

SPEC-41 P1 answered *"is this branch serving anything, and is it answering?"* from the
worktree row. P2 answers the two questions the row cannot:

1. **Host-wide, in one place:** what is listening on this machine, grouped repo → worktree →
   port, filterable to *this repo* / *mine* / *exposed* / *orphans* — the global Ports screen.
2. **What has outlived its branch:** removing a worktree never kills its dev server, so
   `:5180`, `:5181`… pile up for days. P2 names them (**orphans**) and warns when two branches
   want the same port (**collisions**), both derived from a small **port history** file.

Plus three mount points that P1 deliberately deferred: docker attribution (so a published
container port stops reading as an unowned `com.docker.backend`), a menubar entry, and the
`Ports (n)…` item in the worktree overflow menu.

## Why this exists

P1 shipped the data and the per-row surface but left the machine-wide read as "open a
terminal and run `lsof`." The orphan pile-up is the single failure that motivated the whole
feature (SPEC-41's own "Why this belongs in makit"), and it is *undetectable without history*
— which is exactly why P1 could not ship it. P2 adds the one small persistent store that turns
"an unowned port on `/tmp/scratch`" into "the dev server `feat-desktop-tabs` left running when
you deleted it 2 days ago," and gives it a screen to live on.

## What P2 reuses rather than rebuilds

| Need | Reused from | Note |
| --- | --- | --- |
| Persistence that never throws on bad input, degrades to empty, env-overridable | `server/src/project-store.ts` (`loadProjects`/`saveProjects`, `MAKIT_PROJECTS_FILE`, `makitHome()`) | Port history follows this exact shape — a JSON file under `$MAKIT_HOME`, **not** sqlite (D11) |
| A new nav destination beside Home/Archived | `app/lib/app/router.dart` + `routes.dart` (`kRouteArchived`) + `ui/home/archived_screen.dart` | The global screen is `kRoutePorts` + `PortsScreen`, an `AppBar` + filter row + grouped list, entered from a home app-bar icon exactly as Archived is (`home_screen.dart` `context.go(kRouteArchived)`) |
| Grouped-by-repo list with a `_GroupHeader` | `archived_screen.dart` `_grouped` / `_GroupHeader` | Same first-seen-order grouping, one level deeper (repo → worktree → port) |
| Overflow menu with `value:`-keyed items + `onSelected(String)` | `_WorktreeMenuButton` in `desktop/chat/desktop_sidebar.dart` (~line 785) | `Ports (n)…` is one more `PopupMenuItem(value:'ports')` |
| A rebindable keyboard action | `shortcuts/shortcut_action.dart` + `keymap.dart` + `desktop/chat/keymap_scope.dart` | `⌘⇧P` becomes `ShortcutAction.openPorts` (D9) |
| The menubar | `desktop/tray/tray_controller.dart` + `tray_icons.dart` | Ports render as a `Ports (n)` submenu, mirroring the existing `Devices (n)`/`Sessions (n)` submenus (D15) |
| A watch-gated host broadcast (both carve-out halves) | SPEC-41 `ports.snapshot`, SPEC-37 `metrics.sample` | P2b's new optional DTO fields ride the **existing** `ports.snapshot` event — no new event kind, so no new `SessionEventKind` `Exclude<>` / `HOST_ONLY_KINDS` entry is needed |
| Host-wide fixture placement | `server/test/fixtures/snapshots.json` (never `events.json`) | The P2b round-trip goldens extend that same file |
| The `Exec` seam + the never-rejecting runner trap | `git.ts` `run()` (resolves `{code:127,stdout:""}` on a missing binary) | Docker attribution checks `code` explicitly (D13) |
| cwd → longest-segment-prefix worktree match, realpath aliasing | `ports/attribute.ts` (`matchWorktree`, `segments`, `isSegmentPrefix`, `resolveReal`) | Orphan/collision derivation reuses these against *historical* paths |

## Decisions (locked before implementation)

SPEC-41 owns **D1–D7**; they remain locked and P2 must not contradict them. P2's decisions
continue the numbering as **D8–D16** so cross-references inside the ports feature are
unambiguous. D14 is the explicit revisit D1 promised ("Revisit in P2 with the global screen").

| # | Decision | Why |
| --- | --- | --- |
| D8 | **`Ports (n)…` (desktop overflow menu) routes to the global Ports screen**, pre-selecting the *This repo* filter for that worktree's repo — it does **not** lift the popover's controller into `_WorktreeGroupState`. | The popover's open/pinned state (`_PortsPopoverState._open/_pinned/_controller`) is private hover discipline; a menu item pinning it would couple the menu to the popover's internals (SRP / surgical-diff violation). The menu is an *explicit navigation* action, the popover a *hover glance* — different intents. Routing also unifies three affordances onto one screen: this item, the mobile sheet's "Open the Ports screen" button, and the menubar's "Open Ports…". Runner-up (reuse the mobile sheet as a desktop dialog) rejected as a second desktop surface for the same data. |
| D9 | **`⌘⇧P` is a real, rebindable `ShortcutAction.openPorts` (global scope)** that opens the screen, not a display-only label. Verified free in `keymap.dart` (`⌘D`/`⌘⇧D` are the splits; nothing binds `⌘⇧P`). Off-macOS it is `⌃⇧P`. | A shown accelerator that does nothing is a fake affordance — worse than none. Wiring it costs one enum value + one default + one `Intent`, consistent with the existing shortcut system. *Global* scope is correct because the screen is worktree-agnostic; a per-worktree accelerator has no unambiguous target. |
| D10 | **Orphan** = a listening port that is (a) unowned by any *active* worktree **and** (b) whose process cwd longest-segment-prefix-matches a *historical* worktree path that is no longer active. It renders `was <branch>, removed <relative age>` **only when history holds that path**; on empty/first-run history it renders `unowned · cwd <path>` and **never a fabricated date**. | SPEC-41 D7's honesty bar. The former branch and the removal date exist only if we recorded them; inventing a "removed 2d ago" with no history is the "up 56y" lie `portUptimeLabel` refuses to tell. Detection (a)+(b) is possible from P1 data + history; the *label* degrades truthfully when history is thin. |
| D11 | **Orphan/collision derivation is server-side and pure** (`ports/derive.ts`), fed by a **JSON port-history store** (`ports/history_store.ts`, `$MAKIT_HOME/port-history.json`, overridable via `MAKIT_PORT_HISTORY_FILE`) that never throws and degrades to empty — the `project-store.ts` pattern, **not** `storage/sqlite_event_store.ts`. New results ride the existing `ports.snapshot` as optional `PortDTO` fields. | History is a small **bounded map** (worktree path → `{branch, ports[], firstSeen, lastSeen}`), read once and rewritten per scan — not an append-only high-volume log. sqlite earns its keep for the event store's unbounded, queried, concurrent writes; here it would be speculative machinery (YAGNI). Load/save-never-throw keeps a corrupt file from blocking startup, same as `loadProjects`. |
| D12 | **Collision** = a currently-owned port `P` that history attributes to **≥2 distinct still-active worktrees**; the banner names the other branch and **carries no suggested free port**. | Two processes cannot both hold `LISTEN` on the same address:port, so the second worktree's clash is *inherently historical* — it means "starting your dev server here would fail to bind." SPEC-41's phasing puts *suggested port* (`base + hash(branch)`) in **P3**, so the P2 banner states the conflict honestly and stops there. This is the riskiest decision (see Risks). |
| D13 | **Docker is an ownership annotation, not a `reach`.** SPEC-41 D2 locks `reach ∈ {loopback, tailnet, exposed}`. A published container port gets an optional `docker?: {container, compose?}`; its `reach` stays whatever its bind address says. `docker ps` runs **at most once per scan, only while watched, TTL-cached, and its exit `code` is checked explicitly**; a missing daemon/binary (`code:127`, `stdout:""` via `git.ts run()`) yields *no annotation*, never "no containers." | The mockup draws a `docker` reach pill; the shipped D2 contract has no such value — **trust the code**. The `run()`-never-rejects trap would otherwise read "docker not installed" as "zero containers running" and silently mis-attribute. |
| D14 | **The session-tile glyph ships** (D1's revisit), but only when a port's `sessionId` matches that tile's session, is **quieter than the row glyph** (no attention dot — the row already carries attention), and opens the same per-worktree ports surface. App-only: `sessionId` is already on the wire. | It answers a *different* question than the row ("which session spawned this server" vs "is the branch serving at all"), so it is additive, not duplicative. Scoping it to matched sessions stops it lighting on every tile; dropping the attention dot stops it competing with the row's badge for the same alarm. |
| D15 | **The menubar renders the app's last cached snapshot; it never arms the scanner.** The live count goes in the **tooltip** and a `Ports (n)` submenu (owned + system, plus orphans once P2b ships), with an "Open Ports…" item. No kill (P3). | An always-visible menubar count would need an always-held watch → perpetual `lsof`, breaking SPEC-41's watch-gated cost discipline. And `tray_manager` exposes *icon (template PNG) + tooltip + menu* — not a rich menubar badge — so the mockup's inline "🔌 11 · 3" is **not buildable as drawn**; the count lives in the submenu label exactly like `Devices (n)`/`Sessions (n)` already do. |
| D16 | **Scope order: P2a (app-only) → P2b (history + protocol) → P2c (docker + menubar).** P2a and P2c need no history; **P2b and P2c are mutually independent**. Each lands and ships alone. | P2a delivers the whole screen with **zero wire change and zero scan cost**, so the riskiest work (history semantics, docker exec) is isolated behind it and can be reviewed and reverted independently. |

## Phasing (this spec is SPEC-41's P2, split into landable sub-phases)

| Sub-phase | Content | Wire | Scan cost |
| --- | --- | --- | --- |
| **P2a** | Global Ports screen (`kRoutePorts`, filters *All / This repo / Mine / Exposed*, repo→worktree→port grouping, empty/degraded/unowned-only states); `Ports (n)…` overflow item + `⌘⇧P`; mobile sheet's "Open the Ports screen" button; session-tile glyph | **none** — renders the existing `PortsSnapshotDTO` | **none** — no new exec |
| **P2b** | Port history store + orphan/collision derivation; the *Orphans* filter + orphans section; the collision banner (no suggested port) | optional `PortDTO.orphan` / `PortDTO.collision` on the existing `ports.snapshot` | none (pure derive) + one debounced JSON write per scan |
| **P2c** | Docker attribution; menubar `Ports (n)` submenu | optional `PortDTO.docker` | +1 `docker ps` per scan while watched, TTL-cached, skipped when docker absent |

(SPEC-41's own phasing still holds: **P3** = `ports.kill` + kill-all-orphans + suggested free
port; **P4** = forward-a-port + watched ports + notifications.)

## What P2 does not do

- **No kill, no restart, no `ports.kill`, and P2 still sends no signal to any process.** Every
  destructive affordance in the mockup — the menubar `Kill`, "Kill all orphans", the sheet's
  "Kill this process…", "Stop container" — is **P3**. The orphans section is a *reviewable
  list*, not an actuator. P2 remains read-only, exactly as P1 was.
- **No suggested free port.** The collision banner (D12) names the clash but does not compute
  `PORT=5183`; that is P3.
- **No forwarding, no watched ports, no notifications** (P4).
- **No `reach: docker`** (D13 — docker is ownership; reach stays loopback/tailnet/exposed).
- **No auth probing** (`no auth` pill in §6) and **no cpu/rss** (§9 legend third line) —
  killed by SPEC-41 D4/D5. Where the mockup shows them, they are not built.
- **No always-on ambient scan.** The menubar reads cache (D15); the scanner is still armed
  only while a client holds the watch.
- **No per-worktree filter as a first-class chip.** *This repo* is the finest built-in grain
  (the overflow item pre-selects it); a single-worktree filter is not a filter the mockup asks
  for.
- **No UDP, no established connections** (SPEC-41's rule stands).

## Data model

### Port history (P2b) — `server/src/ports/history_store.ts`

A single JSON file, the `project-store.ts` shape:

```ts
/** One remembered worktree: the branch that owned it and the ports it has bound. */
export interface PortHistoryEntry {
  /** Absolute worktree path — the map key. */
  worktreePath: string;
  /** Branch label at last sighting, for the orphan "was <branch>" line. */
  branch: string;
  /** Distinct port numbers this worktree has been seen listening on (bounded). */
  ports: number[];
  /** Epoch ms first recorded. */
  firstSeen: number;
  /** Epoch ms last seen ACTIVE + owning ≥1 listener — drives "removed Nd ago". */
  lastSeen: number;
}

export interface PortHistory {
  entries: PortHistoryEntry[];
}
```

- `loadHistory(file)` → `PortHistory`; a missing/malformed file yields `{entries:[]}` and
  **never throws** (mirrors `loadProjects`).
- `saveHistory(file, history)` → pretty JSON under `$MAKIT_HOME`, dir created, write failure
  logged and swallowed (mirrors `saveProjects`).
- `historyFile()` → `process.env.MAKIT_PORT_HISTORY_FILE ?? join(makitHome(), "port-history.json")`.
- Bounded: entries whose `lastSeen` is older than `HISTORY_TTL_MS` (14 days) are dropped on
  save, and each entry's `ports` is capped. No unbounded growth → no sqlite.

**Upsert cadence.** Each scan, for every *owned* port (worktreePath set), upsert the entry:
set `branch` from the cached repos snapshot, add the port, bump `lastSeen`. The write is
debounced (only when the projection changed) so a steady-state scan does no disk I/O.

### Wire additions (P2b/P2c) — optional fields on the existing `PortDTO`

No new event kind. `ports.snapshot` still carries `PortsSnapshotDTO`; two/three optional
sub-objects are added to `PortDTO` (absent ⇒ not applicable, the P1 rule):

```ts
/** P2b: this port outlived its worktree (D10). Absent unless orphaned. */
export interface PortOrphanDTO {
  /** Historical worktree path whose cwd this port's process still sits under. */
  formerWorktreePath: string;
  /** Branch at last sighting; absent when history never recorded one. */
  formerBranch?: string;
  /** Epoch ms the worktree was last seen active; absent ⇒ render NO date (D10). */
  removedAt?: number;
}

/** P2b: another active worktree also binds this port per history (D12). */
export interface PortCollisionDTO {
  /** The other worktree's branch, for "5173 also wanted by <branch>". */
  withBranch: string;
  withWorktreePath: string;
}

/** P2c: this listener is a docker-published container port (D13). */
export interface PortDockerDTO {
  container: string;
  /** Compose file path when derivable from container labels; else absent. */
  compose?: string;
}

export interface PortDTO {
  // …all P1 fields unchanged…
  orphan?: PortOrphanDTO;      // P2b
  collision?: PortCollisionDTO; // P2b
  docker?: PortDockerDTO;       // P2c
}
```

The Dart mirror (`app/lib/store/ports.dart`) parses each tolerantly — a malformed sub-object
drops to `null` without dropping the port, exactly as `PortHealth.fromJson` already does.

### Derivation (P2b) — `server/src/ports/derive.ts`, pure

`annotate({ports, cwds, procs, history, activeWorktreePaths, resolveReal, now})` returns a new
`PortDTO[]` with `orphan`/`collision` filled in. Pure, no I/O, no throw — like `attribute.ts`:

- **Orphan:** for each port with no `worktreePath`, resolve its process's cwd (own or nearest
  ancestor, reusing `walkAncestors`), longest-segment-prefix-match it against *history* keys
  **not** in `activeWorktreePaths`. A hit → `orphan: {formerWorktreePath, formerBranch?, removedAt?}`.
  When the matched history entry has no branch/`lastSeen`, those fields are omitted and the UI
  shows cwd only (D10).
- **Collision:** for each owned port `P` on worktree `A`, if history shows a *different* still-active
  worktree `B` whose `ports` includes `P`, set `collision: {withBranch, withWorktreePath}` on
  `A`'s port.

`attribute.ts` is **not modified** — derivation is a separate pass in `service.ts.doScan`, fed
the same `cwds`/`procs` it already has, so the P1 attribution path and its tests are untouched.

### Docker (P2c) — `server/src/ports/docker.ts`

`readDockerPorts(exec, timeoutMs)` runs `docker ps --format '{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project.config_files"}}'`,
**checks the exit code** (`code !== 0` → `{ ok:false }`, no annotation, no log spam on the
common no-docker machine), parses `0.0.0.0:5432->5432/tcp` style publish maps into
`Map<hostPort, PortDockerDTO>`, TTL-cached (`DOCKER_TTL_MS`, ~10 s). The service overlays the
annotation onto any listener whose `pid` is the docker backend and whose `port` is a published
host port.

## Component boundaries

```
server/src/ports/
  history_store.ts   NEW  load/save JSON, never throws, bounded (P2b)
  derive.ts          NEW  pure orphan/collision annotation (P2b)
  docker.ts          NEW  `docker ps`, code-checked, TTL-cached (P2c)
  service.ts         EDIT doScan: upsert history → annotate → overlay docker (P2b/P2c)
  protocol.ts        EDIT optional PortDTO.{orphan,collision,docker} (P2b/P2c)
  (attribute/scan/proc/health/ancestors UNCHANGED)

app/lib/
  app/routes.dart              EDIT kRoutePorts
  app/router.dart              EDIT GoRoute → PortsScreen (P2a)
  shortcuts/shortcut_action.dart EDIT ShortcutAction.openPorts (P2a, D9)
  shortcuts/keymap.dart          EDIT default ⌘⇧P (P2a, D9)
  desktop/chat/keymap_scope.dart EDIT Intent → context.go(kRoutePorts) (P2a)
  desktop/chat/desktop_sidebar.dart EDIT _WorktreeMenuButton 'ports' item (P2a, D8)
  ui/home/home_screen.dart       EDIT app-bar plug icon → kRoutePorts (P2a)
  ui/ports/ports_screen.dart     NEW  the global screen (P2a)
  ui/ports/ports_filter.dart     NEW  pure filter/group logic (P2a)
  ui/ports/worktree_ports_sheet.dart EDIT "Open the Ports screen" button (P2a)
  ui/ports/session_ports_glyph.dart  NEW  the session-tile glyph (P2a, D14)
  store/ports.dart               EDIT parse orphan/collision/docker (P2b/P2c)
  desktop/tray/tray_controller.dart EDIT Ports (n) submenu (P2c, D15)
```

## Cost

- **P2a: zero.** No new exec, no wire change; the screen and every new affordance render the
  `PortsSnapshotDTO` already on the wire while a client watches.
- **P2b:** one *pure* derive pass per scan (no exec) and one **debounced** JSON write to
  `port-history.json` (bounded map, only when the projection changed). The wire grows only by
  the `orphan`/`collision` sub-objects on the handful of affected ports — the ~2 KB typical
  snapshot is unchanged for the common all-healthy case.
- **P2c:** one `docker ps` per scan **while watched**, TTL-cached (~10 s) so most ticks reuse
  it, bounded by the existing `EXEC_TIMEOUT_MS`, and **skipped entirely** (after the first
  `code:127`) on machines without docker. Wire grows only by `docker` on published-container
  ports.

## Where the mockup and the shipped code disagree — trust the code

| Mockup shows | Reality | P2 does |
| --- | --- | --- |
| `<span class="reach">docker</span>` (§2a, §3) | `reach` is locked to loopback/tailnet/exposed (D2) | docker is an ownership annotation (D13); reach reflects the real bind |
| Menubar bar renders "🔌 11" + red "3" inline (§7) | `tray_manager` exposes icon + tooltip + menu, no rich menubar badge | count in tooltip + `Ports (n)` submenu label (D15) |
| Menubar `Kill` / "Kill all orphans"; sheet "Kill…" / "Stop container" (§7, §2b) | no signal ships in P2 | omitted — P3 |
| `no auth` health pill on postgres (§6) | no auth probing (D4) | not built |
| cpu / rss on the row's third line (§9) | cut by D5 | not built |
| `PORT=5183` suggested-port button in the collision banner (§2a, §6) | suggested port is P3 | banner names the clash only (D12) |
| Orphan tooltip "removed 2 days ago" always present (§3) | date exists only if history recorded it | date omitted before history (D10) |

## Tests

| Layer | Test file | Assertions |
| --- | --- | --- |
| **P2a** app filter/group | `test/ui/ports/ports_filter_test.dart` | *All* keeps every port; *This repo* keeps only the given repo's owned ports; *Mine* keeps ports with a `worktreePath` (drops system/unowned); *Exposed* keeps only `reach == exposed`; grouping is repo → worktree → port in first-seen order; unowned ports collapse into an "other / system" group; a `scanOk:false` snapshot yields the degraded state, not an empty list |
| **P2a** screen widget | `test/ui/ports/ports_screen_test.dart` | filter chips switch the visible set; empty state ("No dev servers running") when zero ports; degraded banner when `scanOk:false`; unowned-only renders the system group; tapping a port opens the P1 detail sheet (reused); the screen holds the ports watch while mounted and releases on dispose (ref-count returns to 0) |
| **P2a** routing | `test/app/router_ports_test.dart` | `kRoutePorts` builds `PortsScreen`; `?repo=<id>` pre-selects *This repo*; the home app-bar plug icon navigates there |
| **P2a** shortcut | `test/shortcuts/keymap_test.dart` (extend) | `ShortcutAction.openPorts` defaults to `⌘⇧P` (meta) / `⌃⇧P` off-mac; `conflictFor` reports **no** conflict in the global scope |
| **P2a** overflow item | `test/desktop/chat/desktop_sidebar_ports_menu_test.dart` | the menu shows `Ports (n)…` with the worktree's port count; selecting `value:'ports'` navigates to `kRoutePorts` with the repo pre-filter; the item is present regardless of hover-latch state |
| **P2a** session glyph | `test/ui/ports/session_ports_glyph_test.dart` | renders nothing when no port has this `sessionId`; renders (quiet, **no attention dot**) when one does; its semantics label names the session's port; tapping opens the worktree ports surface |
| **P2b** history store | `server/test/ports/history_store.test.ts` | missing file → `{entries:[]}`; corrupt JSON → `{entries:[]}` (no throw); `MAKIT_PORT_HISTORY_FILE` override honoured; upsert adds a port and bumps `lastSeen`; entries past `HISTORY_TTL_MS` dropped on save; save failure swallowed |
| **P2b** derive | `server/test/ports/derive.test.ts` | an unowned port whose cwd matches a *removed* history path → `orphan` with `formerBranch`+`removedAt`; the same with **empty history** → **no `orphan`, no date fabricated** (D10); an unowned system port matching nothing stays plain unowned; an owned port `P` with a second active worktree in history → `collision.withBranch`; a port owned by exactly one worktree → **no** collision; derivation never mutates its inputs and never throws |
| **P2b** protocol contract | `server/test/protocol/contract.test.ts` (extend) + `snapshots.json` | a snapshot carrying `orphan`/`collision` round-trips via `decodeFrame`; **`decodeSessionEvent` still rejects `ports.snapshot`** (the reused `HOST_ONLY_KINDS` half); Dart `codec_contract_test.dart` decodes the same bytes |
| **P2b** app parse + UI | `test/store/ports_test.dart` + `test/ui/ports/ports_screen_test.dart` | `orphan`/`collision` parse tolerantly (malformed sub-object drops to null, port kept); *Orphans* filter shows the orphans section; the "Kill all orphans" control is **absent** (P3); the collision banner names the other branch and shows **no** `PORT=` suggestion (D12) |
| **P2c** docker | `server/test/ports/docker.test.ts` | `code !== 0` → `{ok:false}`, no annotation, no throw (the `run()` 127 trap); a `0.0.0.0:5432->5432/tcp` publish map parses to `{hostPort:5432 → {container}}`; compose path read from the label when present, absent otherwise; the TTL cache reuses within `DOCKER_TTL_MS` and re-reads after |
| **P2c** service overlay | `server/test/ports/service.test.ts` (extend) | a docker-backend listener on a published host port gains `docker`; a machine with no docker (`code:127`) produces a normal snapshot with **no** docker fields and **no** extra cost after the first probe; `reach` is unchanged by the docker annotation (D13) |
| **P2c** menubar | `test/desktop/tray/tray_controller_test.dart` (extend) | the `Ports (n)` submenu lists cached ports; "Open Ports…" is present; **no** `Kill` items exist; with no snapshot the submenu reads "No ports"; the controller never triggers a scan |

## Verification (beyond unit tests)

Per project skill `makit-verify-feature-end-to-end`:

1. `cd server && node_modules/.bin/tsc -p . --noEmit && pnpm test`
2. `cd app && flutter analyze --fatal-infos --no-pub && flutter test --no-pub`
3. **Orphan honesty check (P2b):** start a real listener with `cwd` in a temp worktree, run
   the real scanner once (records history), remove the worktree, rescan — assert the port now
   carries `orphan.formerBranch` and a real `removedAt`; delete `port-history.json`, rescan —
   assert `orphan` is present with cwd but **no date**. This is the machine-verifiable proof
   that D10 never fabricates.
4. **Docker check (P2c), where docker exists:** publish a container port, scan, assert the
   `docker` annotation; stop the daemon, scan, assert the snapshot is normal and unowned (not
   crashed, not "0 containers" mis-read).
5. `tool/e2e.sh --mode=stub` with the P2 cases registered; `test/e2e-server.ts` publishes a
   snapshot carrying one orphan and one collision so the screen exercises the real frame path.
6. A live eyeball on the global screen against `lsof -nP -iTCP -sTCP:LISTEN` on a machine with
   several worktrees + a removed one, because only a human notices a *plausible but wrong*
   orphan owner.
