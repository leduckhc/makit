## Debug Mode: Desktop App on Worktree

When developing on a feature branch, run the desktop app against an isolated
daemon on your worktree's profile (`~/.makit-dev/<hash>`). Hot reload and
breakpoints work normally.

### Command Line (Fastest)

```bash
./scripts/debug-desktop.sh
```

This:
1. Derives your worktree's profile hash from the repo root
2. Starts the daemon on an isolated port (7800–7899 range)
3. Launches the app with `dart-define`s pointing to that daemon
4. Hot reload + breakpoints work; Ctrl-C stops both

**Options:**
```bash
./scripts/debug-desktop.sh --no-app   # start daemon only (daemon runs detached)
./scripts/debug-desktop.sh --kill     # stop the daemon gracefully
```

### VS Code Launch (with Breakpoints & Hot Reload)

1. Open this worktree in VS Code (File > Open Folder > `sc-quantum-squid-b72e/`)
2. Press **F5** or Run > Start Debugging
3. Select **"Makit Desktop (Debug, Isolated Profile)"**
4. Daemon starts automatically; app launches in debug mode
5. Use breakpoints, hot reload (R), and hot restart (Shift-R) as normal

The `.vscode/launch.json` and `tasks.json` handle:
- Pre-launch: `scripts/debug-desktop.sh --no-app` starts the daemon
- Post-debug: `scripts/debug-desktop.sh --kill` stops it cleanly
- Environment: Reads from task output (fingerprint + bearer auto-computed)

### What's Different from Main

- **Daemon home:** `~/.makit-dev/<hash>` (isolated)
- **Port:** `7800–7899` (stable per worktree, never collides with main's 7777)
- **Secure store:** `~/Library/Application Support/dev.getmakit.app/secure_store.<hash>.json` (isolated)
- **Projects:** `~/.makit-dev/<hash>/projects.json`
- **Window title:** Shows "Makit — makit" + colored badge in sidebar
- **CLI:** Bundled inside `makit.app/Contents/Resources/makit/makit` (self-contained)

### Logs

While debugging:
```bash
tail -f ~/.makit-dev/<hash>/makit.log     # daemon log (real-time)
tail -f ~/.makit-dev/<hash>/makit.pid     # daemon PID (if running)
```

The daemon fingerprint is logged to the terminal at startup; use it for manual
client pairing (QR code).

### Troubleshooting

**App stuck on "Reconnecting"?**
- Daemon crashed; check `~/.makit-dev/<hash>/makit.log`
- Run `./scripts/debug-desktop.sh --kill` then `./scripts/debug-desktop.sh` again

**Port already in use?**
- Stray daemon from a previous session; `pkill -f "makit.*serve"` cleans it

**Hot reload not working?**
- Rebuild the server: `cd server && pnpm run build`, then hot reload the app
- Full rebuild: `flutter build macos --release` (without --debug)

**Bearer rejected by daemon?**
- The test bearer is one-shot; if you restart the daemon, the app's bearer
  becomes stale. Kill the daemon (`--kill`) and relaunch the app.
