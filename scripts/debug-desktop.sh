#!/usr/bin/env bash
# Run the makit desktop app in DEBUG (hot reload) against a worktree's server.
#
# Uses the "dev loop": a plain `tsx` server on loopback + `flutter run` wired to
# it via --dart-define=MAKIT_WS_URL/MAKIT_FP. The app's `_boot()` sees
# MAKIT_WS_URL and connects directly (no pairing, no bundled CLI needed — see
# app/lib/store/connection.dart). This is independent of the app's per-build
# ServerProfile: the app talks to exactly the URL we pass here.
#
# Modes:
#   debug-desktop.sh [WORKTREE]              # start server + flutter run (default)
#   debug-desktop.sh --server-only [WORKTREE] # server in foreground (VSCode task)
#   debug-desktop.sh --print-fp   [WORKTREE]  # print the server cert fingerprint
#   debug-desktop.sh --kill       [WORKTREE]  # stop this worktree's debug server
#
# WORKTREE defaults to the git repo root of the current directory.
# Env overrides: MAKIT_DEBUG_PORT, MAKIT_DEBUG_HOME, FLUTTER_BIN.
set -euo pipefail

MODE=run
case "${1:-}" in
  --server-only) MODE=server; shift ;;
  --print-fp)    MODE=fp; shift ;;
  --kill)        MODE=kill; shift ;;
esac

# Resolve the worktree (explicit arg wins, else the enclosing git repo).
WT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WT="$(cd "$WT" && pwd)"

# A dedicated, per-worktree debug home + port so several worktrees can run at
# once without colliding. The hash only needs to be stable + unique per path;
# it does NOT need to match the app's ServerProfile (we use MAKIT_WS_URL).
ID="$(printf '%s' "$WT" | shasum -a 256 | cut -c1-8)"
DEBUG_HOME="${MAKIT_DEBUG_HOME:-$HOME/.makit-debug/$ID}"
PORT="${MAKIT_DEBUG_PORT:-$((7900 + 0x$ID % 100))}"
CRT="$DEBUG_HOME/server.crt"
WS_URL="wss://127.0.0.1:$PORT"

FLUTTER="${FLUTTER_BIN:-flutter}"
command -v "$FLUTTER" >/dev/null 2>&1 || FLUTTER="$HOME/Work/Vibe/flutter/bin/flutter"

fp() { openssl x509 -in "$CRT" -outform der | shasum -a 256 | cut -d' ' -f1; }

# The bundle step (pnpm deploy) can prune the workspace's dev deps, leaving a
# dangling `tsx`. Restore them if the runner is missing so debug always works.
ensure_deps() {
  if [ ! -f "$WT/server/node_modules/tsx/package.json" ]; then
    echo "==> restoring server dev deps (tsx missing) …"
    ( cd "$WT/server" && pnpm install --frozen-lockfile >/dev/null 2>&1 )
  fi
}

kill_server() {
  MAKIT_HOME="$DEBUG_HOME" pkill -f "tsx .*serve.* --port $PORT" 2>/dev/null || true
}

if [ "$MODE" = kill ]; then
  kill_server; echo "stopped debug server for $WT (port $PORT)"; exit 0
fi

start_server() {
  ensure_deps
  mkdir -p "$DEBUG_HOME"
  echo "==> starting server  home=$DEBUG_HOME  $WS_URL  project=$WT"
  ( cd "$WT/server" && MAKIT_HOME="$DEBUG_HOME" \
      pnpm exec tsx src/index.ts serve --no-auth --host 127.0.0.1 \
      --port "$PORT" --project "$WT" ) &
  SERVER_PID=$!
  for _ in $(seq 1 100); do [ -f "$CRT" ] && return 0; sleep 0.1; done
  echo "server did not create $CRT" >&2; exit 1
}

case "$MODE" in
  fp)
    if [ ! -f "$CRT" ]; then start_server; fi
    fp
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    ;;
  server)
    # Foreground for the VSCode background task; Ctrl-C / task stop ends it.
    ensure_deps
    mkdir -p "$DEBUG_HOME"
    echo "==> starting server  home=$DEBUG_HOME  $WS_URL  project=$WT"
    cd "$WT/server"
    exec env MAKIT_HOME="$DEBUG_HOME" pnpm exec tsx src/index.ts serve \
      --no-auth --host 127.0.0.1 --port "$PORT" --project "$WT"
    ;;
  run)
    trap 'kill "${SERVER_PID:-}" 2>/dev/null || true' EXIT INT TERM
    start_server
    FP="$(fp)"
    echo "==> flutter run -d macos  ($WS_URL, fp ${FP:0:12}…)"
    cd "$WT/app"
    "$FLUTTER" run -d macos \
      --dart-define=MAKIT_WS_URL="$WS_URL" \
      --dart-define=MAKIT_FP="$FP"
    ;;
esac
