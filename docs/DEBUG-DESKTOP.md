## Debug Mode: Desktop App on Worktree

When developing on a feature branch, run the desktop app in DEBUG (hot reload)
against a plain `tsx` server for your worktree. The server binds loopback with
`--no-auth`; the app connects directly via `--dart-define=MAKIT_WS_URL` +
`MAKIT_FP` (cert pinning) — no pairing, QR, bearer, or bundled CLI involved.
This is independent of the app's per-build `ServerProfile`; the app talks to
exactly the URL the script passes.

Each worktree gets its own debug home (`~/.makit-debug/<hash>`) and a port in
the `7900–7999` range derived from the worktree path, so several worktrees can
run at once. Override either with `MAKIT_DEBUG_HOME` / `MAKIT_DEBUG_PORT`.

### Command Line (Fastest)

```bash
./scripts/debug-desktop.sh
```

This:
1. Derives a per-worktree debug home + port from the repo root
2. Starts the `tsx` server on loopback (`wss://127.0.0.1:<port>`, `--no-auth`)
3. Runs `flutter run -d macos` wired to it via `MAKIT_WS_URL` + `MAKIT_FP`
4. Hot reload + breakpoints work; Ctrl-C stops both

**Options:**
```bash
./scripts/debug-desktop.sh --server-only  # server in foreground (no flutter run)
./scripts/debug-desktop.sh --server-only --inspect  # …under the Node inspector
./scripts/debug-desktop.sh --print-fp     # print the server cert fingerprint
./scripts/debug-desktop.sh --kill         # stop this worktree's debug server
```

`--inspect` runs the server as `node --inspect --import tsx`, listening on
`127.0.0.1:9229` (override with `MAKIT_INSPECT_PORT`), so a debugger can attach
and break in `server/src/**.ts`.

All modes accept an optional `[WORKTREE]` path (defaults to the enclosing git
repo root).

### VS Code Launch (with Breakpoints & Hot Reload)

1. Open this worktree in VS Code (File > Open Folder)
2. Press **F5** or Run > Start Debugging
3. Select **"makit desktop (debug, worktree server)"**
4. When prompted, enter the **debug port** (any free port; pick a distinct one
   per worktree) and the **cert fingerprint**
5. The `makit: debug server` task starts the server; the app launches in debug
   mode. Use breakpoints, hot reload (R), and hot restart (Shift-R) as normal.

Get the fingerprint once with (using the same port you'll enter):
```bash
MAKIT_DEBUG_PORT=<port> ./scripts/debug-desktop.sh --print-fp
```
Both the `makitPort` and `makitFp` prompts are remembered per worktree, so after
the first run F5 just launches.

> The debug port and the launch URL are driven by the same `makitPort` input, so
> they always match. Stopping the debug session ends the server task.

#### Server-side breakpoints (TypeScript)

To break in the server as well as the app, pick the compound **"makit full stack
(app + server breakpoints)"**. It starts the `makit: debug server (inspect)`
task, attaches the Node debugger on `127.0.0.1:${makitInspectPort}`, and launches the app with
**"makit desktop (debug, attach to running server)"** (same `MAKIT_WS_URL` /
`MAKIT_FP` prompts, but no server task of its own). Breakpoints in
`server/src/**.ts` and in `app/lib/**.dart` are live at the same time; stopping
either session stops both (`stopAll`).

Run **"makit server (attach to debug server)"** alone when only the server
matters (e.g. driving it from the CLI or an already-installed app build).

> Like `makitPort`, the `makitInspectPort` input lives in both `launch.json`
> (Node attach) and `tasks.json` (the inspect task's `MAKIT_INSPECT_PORT`), so
> the compound prompts for it twice — enter the same value both times (the
> defaults match at `9229`, and VS Code remembers your last entry). Pick a free
> port per worktree so two full-stack sessions don't collide on the inspector.

### Other VS Code entries

Launch configurations:

| Configuration | Purpose |
|---|---|
| `makit desktop (debug, worktree server)` | App + plain debug server (original one-key flow) |
| `makit desktop (debug, attach to running server)` | App only — server already running |
| `makit server (attach to debug server)` | Node inspector attach for `server/src` |
| `makit server test (current file)` | `node --import tsx --test` on the open test file |
| `makit app test (current file)` | Dart/Flutter test on the open test file |

Tasks (⇧⌘P → *Run Task*): `makit: debug server`, `makit: debug server
(inspect)`, `makit: kill debug server`, `makit: print server cert fingerprint`,
`makit: server typecheck` (default build task), `makit: server test` (default
test task), `makit: app analyze`, `makit: app test`, and `makit: build macOS app
(debug) + open` (full `scripts/macos-app.sh` build + CLI embed + launch — a
non-hot-reload build, use it to check the shipping path).

### What's Different from Main

- **Server home:** `~/.makit-debug/<hash>` (isolated per worktree)
- **Port:** `7900–7999` (derived per worktree; override with `MAKIT_DEBUG_PORT`)
- **Server:** plain `tsx src/index.ts serve --no-auth --host 127.0.0.1` (no
  daemon, no bundled CLI); output goes to the terminal / VS Code task panel
- **Connection:** direct `MAKIT_WS_URL` + `MAKIT_FP` cert pinning (no pairing)

### Logs

The server runs in the foreground, so its output appears in the terminal (CLI
mode) or the dedicated task panel (VS Code). There is no `makit.log`/`makit.pid`
in debug mode.

### Troubleshooting

**App stuck on "Reconnecting"?**
- The server exited; re-check the terminal / task panel output.
- Run `./scripts/debug-desktop.sh --kill` then `./scripts/debug-desktop.sh` again.

**Port already in use?**
- A stray debug server from a previous session. Stop just this worktree's
  server (scoped to its port) with:
  ```bash
  ./scripts/debug-desktop.sh --kill
  ```

**Server-side changes not taking effect?**
- The debug server runs `tsx` directly on the TypeScript source, so `pnpm run
  build` (which only writes `dist/`) does nothing for it. Stop and restart the
  debug server task (VS Code) or rerun `./scripts/debug-desktop.sh` to pick up
  server changes, then hot reload the app for UI changes.

**`tsx` missing / server won't start?**
- The bundle step can prune dev deps; the script restores them automatically,
  or run `cd server && pnpm install --frozen-lockfile` manually.
