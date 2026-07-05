# SPEC-05 — Session-in-pane spawning + lifecycle

**Status:** ready · **Depends on:** SPEC-04 (mux adapter) · **Touches:**
`server/src/manager.ts`, `server/src/server.ts`, `server/extensions/pino-mirror.ts`,
app session DTO/UI

## Goal

When a **new session is created** (from the phone app or `pino`), pino should
launch `pi` in a **new background (unfocused) pane** of the active multiplexer
(SPEC-04), which the user can attach to in the terminal. That `pi` mirrors to the
phone (World-D path). The pane is **labeled** and **auto-closes when the session
ends or is quit**. The phone shows which pane a session is running in.

## Why

Consensus #5: phone-initiated sessions should be attachable background panes, not
hidden headless children; and the pane should auto-close on session end.

## Background (important architectural note)

Today `session.spawn` → `manager.spawnPiSession` → `createSession` spawns a
**headless `pi --mode rpc` child** (World A / `PiAdapter`) that lives nowhere
attachable. This spec changes phone-initiated spawns to the **pane + World-D
mirror** model:

1. pino asks the mux adapter to open a background pane and run a `pi` launch
   command in the session's project cwd, passing a **correlation token** via env.
2. That `pi` auto-loads `pino-mirror` (already symlinked). The extension reads the
   correlation token and includes it in its `host.open` frame.
3. pino matches the incoming `host.open` (by token) to the pending spawn request,
   binds the resulting World-D session, and records the `PaneHandle` on it.
4. On session end/quit/`host.close`, pino calls `adapter.closePane(handle)`.

This means World-D `host.open` must carry a correlation id, and pino must be able
to spawn pi with that id in the environment.

## Scope

### In
- **Correlation:** generate a `spawnToken` per pane-spawn; launch `pi` with
  `PINO_SPAWN_TOKEN=<token>` in the pane. Extend `pino-mirror`'s `host.open` to
  include `spawnToken` (read from `process.env.PINO_SPAWN_TOKEN`). Server matches
  it to the pending spawn and resolves the `session.spawn` ack with that session
  id. Add a timeout (pi failed to launch) that errors the spawn and closes the pane.
- **Spawn path:** `manager` gains a `spawnPiSessionInPane(projectId, opts)` (or a
  flag on `spawnPiSession`) that uses `getMultiplexer()` to open the pane. The
  pane runs something like: `cd <cwd> && PINO_SPAWN_TOKEN=<t> pi` (respect
  `PINO_PI_BIN`). Background/unfocused.
- **Pane record + lifecycle:** store `PaneHandle` on the `Session` (World-D). On
  `host.close`, session kill (`/quit` → `session.kill`), or pi exit, call
  `closePane` (idempotent). Auto-close is the default (consensus #5).
- **Labeling:** set pane label to `pino: <session title>`; update it when the
  title changes (ties into the existing retitle path). Use optional chaining:
  `await mux.setLabel?.(handle, label)` — rename is mux-specific (herdr yes;
  future tmux/cmux may omit `setLabel`).
- **Phone visibility:** add pane info to the session DTO/`session.meta` (e.g.
  `{ pane: { mux, paneId } }`) and surface a subtle "⧉ herdr w7:pX" affordance in
  the app session header so the user knows where to attach.
- **Fallback:** if no multiplexer is available (`isAvailable()` false) or spawn
  fails, fall back to the current headless `PiAdapter` spawn and mark the session
  as not attachable (don't break the feature on non-herdr hosts).
- **Config/toggle:** honor a setting to enable/disable pane-spawning (default on
  when a mux is available); env `PINO_MUX=off` disables.

### Herdr host setup (prerequisite)

Pane spawning calls SPEC-04's `HerdrAdapter.spawnPane`, which runs:

```bash
herdr pane split <anchor> --direction down --cwd <cwd> --no-focus
```

**Important (verified in SPEC-04 smoke test, herdr v0.7.1):** herdr's `pane split`
takes a **pane id** (e.g. `w1:p1`), not a workspace label. The SPEC-04 default
anchor `"pino"` is a *workspace label* — it does **not** resolve as a split
target and returns `pane_not_found`.

Before pane spawning works on a herdr host, the user (or first-run bootstrap)
must:

1. Have a running herdr server (`herdr` or `herdr server`).
2. Create a dedicated workspace for pino sessions (once per host):

   ```bash
   herdr workspace create --cwd ~/your-project --label pino --no-focus
   ```

3. Set the split anchor to that workspace's **root pane id** (from the create
   JSON, e.g. `w1:p1`), via env or config:

   ```bash
   export PINO_MUX_ANCHOR=w1:p1
   ```

   Or in `~/.pino/config.json`:

   ```json
   { "mux": { "name": "herdr", "anchor": "w1:p1" } }
   ```

New panes split from that anchor pane, keeping phone-initiated sessions out of
the user's active layout. Re-check the pane id if workspaces are recreated
(herdr assigns new ids).

**SPEC-05 implementer note:** if `getMultiplexer()` is available but spawn fails
with `pane_not_found`, treat it like mux unavailable and fall back to headless
spawn (log a one-line hint about `PINO_MUX_ANCHOR`). Optional follow-up: auto-
bootstrap a `pino` workspace and cache its root pane id — out of scope for v1
(YAGNI); document the manual setup instead.

Manual smoke (after setup; script at `server/test/mux-herdr.smoke.ts`):

```bash
cd server
PINO_MUX=herdr PINO_MUX_ANCHOR=w1:p1 tsx test/mux-herdr.smoke.ts
# → SPEC-04 herdr smoke: PASS
```

See [herdr quick start](https://herdr.dev/docs/quick-start/) and
[install](https://herdr.dev/docs/install/).

### Out
- The mux mechanism itself — SPEC-04.
- Externally, user-launched `pi` (pure World D) is unchanged — it still
  self-registers with no pane handle (pino didn't spawn it, so it won't close it).

## Contracts touched
- `pino-mirror.ts`: `host.open` gains `spawnToken?: string` (from env). No behavior
  change when the env var is absent (backwards compatible with user-launched pi).
- `server.ts` `host.open` route: if `spawnToken` matches a pending spawn, resolve
  it and attach the `PaneHandle`; else behave as today.
- `Session`/DTO: optional `pane?: { mux: string; paneId: string }`.
- `session.meta` (or sessions.snapshot): include `pane` so the app can display it.

## Acceptance criteria
- [ ] Creating a session from the phone opens a **new unfocused herdr pane**
      running `pi` in the correct project cwd; the phone session becomes live and
      mirrors that pi.
- [ ] The pane is labeled `pino: <title>` and updates on rename.
- [ ] The phone session header shows the pane locator (mux + paneId).
- [ ] Attaching to the pane in the terminal shows the same live `pi` session.
- [ ] `/quit` (or `session.kill`) on the phone **closes the pane**; quitting `pi`
      in the terminal ends the phone session (and pane already gone) — no orphans.
- [ ] If `pi` fails to launch within the timeout, `session.spawn` errors cleanly
      and the pane is closed.
- [ ] On a host without a multiplexer, spawn falls back to headless and still works.
- [ ] Tests: manager spawn path with a **fake MultiplexerAdapter** + fake spawn —
      assert pane opened with the right cwd/command/label, token correlation
      resolves the session, and `closePane` is called on each end path (host.close,
      kill, pi-exit). Extension unit: `host.open` includes `spawnToken` when env
      set, omits it otherwise. `pnpm test` green, `pnpm typecheck` clean; app
      `flutter analyze --fatal-infos` clean + reducer/DTO test for `pane`.

## Open questions (resolve + document)
- **Correlation transport:** env var (`PINO_SPAWN_TOKEN`) is simplest and robust.
  Confirm the mux `run` command can set env (herdr `pane run` runs a shell string,
  so `PINO_SPAWN_TOKEN=... pi` works). Alternative: `pi` CLI flag.
- **Spawn timeout** value (e.g. 15s) and the error surfaced to the app.
- **Auto-close grace:** close immediately on session end, or leave a brief window?
  Consensus said auto-close — close immediately; document. (If a user wants to
  read scrollback, they attach before quitting.)
- **Which pi binary / args** the pane runs (respect `PINO_PI_BIN`, project cwd,
  and any resume flags). Ensure it does NOT set `PINO_BRIDGE_URL` (that env makes
  `pino-mirror` bail — see extension guard).
- **Herdr split anchor:** resolved — see **Herdr host setup** above. `PINO_MUX_ANCHOR`
  / `mux.anchor` must be a pane id (e.g. `w1:p1`), not the workspace label `"pino"`.
  On `pane_not_found`, fall back to headless spawn and log setup hint.
