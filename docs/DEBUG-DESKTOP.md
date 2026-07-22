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
./scripts/debug-desktop.sh --print-fp     # print the server cert fingerprint
./scripts/debug-desktop.sh --kill         # stop this worktree's debug server
```

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

**Hot reload not working?**
- Rebuild the server: `cd server && pnpm run build`, then hot reload the app.

**`tsx` missing / server won't start?**
- The bundle step can prune dev deps; the script restores them automatically,
  or run `cd server && pnpm install --frozen-lockfile` manually.
