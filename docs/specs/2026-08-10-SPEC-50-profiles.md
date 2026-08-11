# SPEC-50 — Profiles: one server per purpose, and a Server panel you can read

**Status:** Implemented · **Priority:** P1 · **Branch:** `feat/profiles`
**Mockup:** [`mockups/server-settings-and-profiles.html`](../../mockups/server-settings-and-profiles.html) (12 cards, the visual ground truth)
**Depends on:** SPEC-48 (`app/lib/status/` — used as the failure sink), SPEC-13 (settings section layout)

**Scope:** `app/lib/desktop/daemon/` (profile model, registry, runtime, lifecycle),
`app/lib/store/prefs/` (scoped prefs), `app/lib/desktop/settings/` (Server + Profiles sections),
`app/lib/desktop/chat/server_profile_badge.dart` (switcher), `app/lib/desktop/desktop_app.dart`
(runtime wiring), `server/src/pairing/url.ts` (two optional query params).

**No change to:** the wire protocol (frames, `v:1`, bearer auth), `MAKIT_HOME` as the isolation
boundary, `chooseBindHost()` semantics, the daemon spawn path, or any server storage module.

---

## Goal

Two complaints, one root cause.

1. **The Server panel exposes ten controls to do one thing: run the server.** Six concepts, four
   of them read-only trivia, plus a four-way segmented control with two labels for one behaviour.
2. **Profiles already exist but are invisible plumbing.** They are *derived* from the running
   `.app`'s filesystem path, never persisted, never nameable — so they cannot express
   Work / Personal, they break when a worktree moves, and there is no way to stop or discard one.

The root cause is the same: the app models **the daemon's configuration** where it should model
**the user's purpose**. A profile is the missing noun.

## Evidence (measured on the author's machine, 2026-08)

```
~/.makit-dev:  33 profile homes   732 MB total
                6 map to a live folder   649.6 MB
               27 ORPHANED (82%)          82.5 MB   ← unreachable by any UI
```

27 of 33 dev profiles are unreachable: their `.app` is gone, so `ServerProfile.resolve()` can
never mint their id again. Nothing can list, stop, or delete them. Each still holds a device
pairing and a TLS keypair. The honest headline is the **count**, not the bytes.

Separately, one *live* profile (`~/Work/Vibe/makit`) holds a 544 MB `makit.db` + 99 MB `media/`.
That is session retention, **explicitly out of scope** (see "What this spec does not do").

## Decisions

**D1 — A profile is its own server instance, and several may run at once.** Own `MAKIT_HOME`,
daemon, port, devices, projects. This is already how the app spawns the daemon
(`desktop_app.dart` passes `environment: profile.environment`); the spec makes it *chosen and
persisted* rather than derived. Rejected: one server with profile-scoped projects (kills the
develop-server case, and a dev crash takes the work server with it); one-at-a-time switching
(loses the ability to watch Work while testing Dev).

**D2 — `~/.makit` becomes a named, renameable profile.** The `isDefault` boolean fused two
unrelated concerns and is split:

| field | meaning | mutable |
|---|---|---|
| `name` | what the user calls it | yes |
| `storage` | `legacy` \| `namespaced` — which key layout it uses | **never** |

`storage: "legacy"` (**at most one** profile) pins the prefs prefix and the unsuffixed
secure-store file, so no shipped user's settings move. It also **implies protected**: it is by
definition the profile holding `AuthKey_*.p8`, `ota/`, `push.json`, `host.json`, so no separate
`protected` flag exists. Delete is *absent* for it, not disabled.

**D3 — Identity is minted once and persisted; `origin` is a relocation hint.** `~/.makit/profiles.json`
is the registry. `id` is generated at creation and never re-derived. `origin` (the repo root a dev
profile was created from) is used to (a) re-bind a moved/rebuilt dev build to its existing profile
instead of forking a new one, and (b) detect orphans via `existsSync(origin)`. Path-hashing
survives **only** as the bootstrap for a dev build the registry has never seen.

**D4 — The port is allocated once, by probing, and persisted.** `7800 + fnv1a(repoRoot) % 100`
becomes a *starting guess*; creation probes upward for a free port and stores the result. Daemon
start retries on `EADDRINUSE`. Note the server already diagnoses a collision well
(`server.ts:199` logs cause + fix; `service.ts` waits for the control socket, clears the pid file,
exits 1) — the gap is that nothing reallocates.

**D5 — Reachability is one question with two answers, plus a fallback checkbox.**
`ServerBindMode {auto,lan,loopback,custom}` → `Reachability {thisMacOnly, myDevices}` +
`allowLanFallback: bool`; `customHost` survives behind Diagnostics → Advanced.
**`chooseBindHost()` is NOT changed.** Re-reading it settled that `--lan` is a documented
*fallback* for when Tailscale is down, and `--host` bypasses the decision entirely
(`serve.ts:82`), so `Loopback`/`Custom` are exact. The defect was the four-segment exclusive
control promising four outcomes when three exist. Migration: persisted `auto`/`lan` → `myDevices`
(`lan` also sets `allowLanFallback: true`); `loopback` → `thisMacOnly`; `custom` → `myDevices`
with `customHost` retained and Advanced revealed.

**D6 — The Server section is four rows:** active-profile row, the reachability question, a pair
row, and one collapsed **Diagnostics** disclosure holding pid, port, bind host, fingerprint, CLI
path, log path and Advanced. `Install CLI` moves to General. The retired item anchors
(`server_devices.lifecycle`, `.cli`, `.fingerprint`) must still resolve, pointing into Diagnostics,
so deep links and settings search keep working.

**D7 — Lifecycle attaches to a profile, not to "the server".** The Server section never offers
Stop (stopping the server you are talking to disconnects the window that asked). The Profiles
section offers Stop/Start per profile. Per-profile stop reuses the existing verb:
`MAKIT_HOME=<home> makit stop` (`server/src/index.ts:130` → `daemon.stop()`).

**D8 — Delete is atomic across four stores, and says what it keeps.** A profile is not one
directory: (1) `$MAKIT_HOME/` (`makit.db` +`-shm`/`-wal`, `media/`, `devices.json`,
`projects.json`, `server.crt`/`.key`, `port-history.json`, `watched-ports.json`,
`capability-cache.json`, `worktree-targets.json`, `makit.log`, `control.sock`), (2) `NSUserDefaults`
keys under the profile's key segment, (3) the secure-store namespace (pairing bearer), (4) the
registry entry. Deleting only the folder leaks the other three; omitting (4) resurrects the
profile empty on next launch. Delete **stops the daemon first** (SIGTERM → SIGKILL after 300 ms)
— never unlink under a live daemon holding `makit.db-wal`. It refuses the `legacy` profile always,
and the active profile unless the user takes the offered "switch away and delete" path. Running
sessions are counted and named in the sheet. **No path outside `~/.makit*` is ever touched.**

**D9 — Orphans are offered, never reaped.** A dev profile whose `origin` no longer exists is
listed as stale with its size, selectable, and deletable in bulk. Auto-deletion is rejected: it
would have prevented all 27 orphans and also destroyed transcripts the first time a worktree moved
or a drive unmounted.

**D10 — Switching happens in the current window, gated by confirm-then-verify.**
1. confirm sheet (what changes here vs. what keeps running),
2. start the target and await its `control.sock` **while the current profile is still live**,
3. only then dispose the old runtime, rebuild `ProviderScope(key: ValueKey(profileId))`, retitle
   the window,
4. on failure stay put and post a `StatusCenter` failure.

Rejected: relaunching the window (flashes the app, loses position, is the "restart to apply"
friction this spec exists to remove).

**D11 — Prefs are scoped by an app-owned key prefix, not by `SharedPreferences.setPrefix`.**
`setPrefix` throws `StateError('setPrefix cannot be called after getInstance')`
(`shared_preferences_legacy.dart:57`), which alone makes D10 impossible; `resetStatic()` is
`@visibleForTesting` and is rejected. Keys are plain concatenation — `'$_prefix$key'` (line 179) —
so moving the profile segment from the global prefix into our own key yields a **byte-identical**
stored key (`flutter.<id>.desktop_server_port` either way). **The migration is a no-op.**
Only *server-bound* prefs are scoped: server config, groups, pane layouts. Appearance, shortcuts,
recent models and cached commands are **user-level and stay shared** — today's blanket prefix is
why a worktree build opens with a default theme and empty shortcuts.

**D12 — The pair URL gains two optional params.** `&n=<name>` and `&id=<profileId>` so the phone
can label and colour each paired server instead of showing a bare IP. Absent → fall back to
`host:port`. `n` is capped at 64 Unicode code points (`MAX_PROFILE_NAME_CODE_POINTS` in
`pairing/url.ts`), truncated on code-point boundaries so a multi-unit emoji is never split, because
the URL is rendered into a QR code of finite capacity. No protocol version bump; per-profile
pairing already works because the QR already carries `host`, `port` and `fp` (`pairing/url.ts`).

## Phases

| Phase | Content | Deltas (mockup card 12) | Status |
|---|---|---|---|
| **P0** | Surface daemon failures | 1 | **Implemented** |
| **P1** | `ProfileRegistry`, profile model split (D2/D3), port allocation + retry (D4) | 2–5 | **Implemented** |
| **P2** | `ProfileScopedPrefs` (D11), per-profile lifecycle + deleter (D7/D8) | 8 | **Implemented** |
| **P3** | Server section rewrite (D5/D6), Profiles section + detail + delete + reclaim (D7/D8/D9) | 6, 7, 12–16 | **Implemented** |
| **P4** | Pair-URL params (D12) | 19 | **Implemented** |
| **P5** | In-place switching (D10) + `ProfileRuntime` | 9–11 | **Implemented** |

## Correction recorded

Rev 1 deferred D10, arguing that `WorkspaceController` needed a 20-file refactor
and that a partial adoption would leave the window showing another profile's
panes. **That was wrong on its central fact:** `WorkspaceController` holds no
preferences at all — its only mention of `SharedPreferences` is a doc comment —
and pane layouts persist through `GroupsController`. The earlier figure counted
files that merely *mention* the class. With only `ServerConfigController` and
`GroupsController` needing the scoped view, D10 was materially cheaper than
claimed, and it is now implemented.

## What this spec does not do

- **Session retention / db pruning.** The 544 MB `makit.db` and 99 MB `media/` in the live profile
  are a retention problem. Deleting profiles will not touch them. Own spec.
- **A designated "primary" profile** holding a stable 7777 and the phone pairing. Right end state,
  wrong first step: it adds promote/demote and a second class of profile before anyone asks.
- **A detected-address dropdown** (delta 18). Needs a new `net.interfaces` command; the address row
  renders the *current* bind host read-only until then.
- **Mobile profile management.** The phone gains labels/colours from D12 only; it does not create,
  stop or delete profiles.
- **Auto-reaping orphans** (D9), **changing `chooseBindHost`** (D5).
- **Migrating the 27 existing orphans automatically.** They are listed and offered; the user decides.

## Verification

1. `cd app && flutter analyze --no-pub` → "No issues found"; `dart format --set-exit-if-changed lib test` clean.
2. `cd server && pnpm typecheck` clean; `pnpm test` green with the pre-existing count preserved.
3. Every new test's bite proven by reverting only the production line.
4. Live proof: a real second profile created, started on its own port, switched into in-place, and
   deleted — with `~/.makit-dev` inspected before and after to confirm all four stores went.
5. `flutter test --no-pub` judged against the known flake baseline: only NON-`loading` failures count.
