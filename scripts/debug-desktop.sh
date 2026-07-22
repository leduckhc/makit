#!/usr/bin/env bash
# Debug mode for desktop app on a worktree — starts the isolated daemon and launches the app.
# Usage:
#   ./scripts/debug-desktop.sh              # start daemon + launch app in debug
#   ./scripts/debug-desktop.sh --no-app     # start daemon only (daemon runs detached)
#   ./scripts/debug-desktop.sh --kill       # stop the daemon
#
# The app connects via dart-defines (MAKIT_WS_URL + MAKIT_FP) to the daemon on
# this worktree's isolated profile (~/.makit-dev/<hash>). Hot reload works.
# Logs: ~/.makit-dev/<hash>/makit.log

set -e

cd "$(dirname "$0")/.."

# Derive this worktree's server profile (matches app/lib/desktop/daemon/server_profile.dart)
derive_profile() {
  local repo_root="$PWD"
  local hash=$(echo -n "$repo_root" | shasum -a 256 | cut -c1-8)
  echo "$hash"
}

PROFILE_ID=$(derive_profile)
MAKIT_HOME="$HOME/.makit-dev/$PROFILE_ID"
PORT=$((7800 + $(printf "%d" 0x$PROFILE_ID) % 100))
SERVER_CERT="$MAKIT_HOME/server.crt"

case "${1:-}" in
  --kill)
    # Stop the daemon gracefully
    if pgrep -f "makit.*serve.*--port $PORT" >/dev/null 2>&1; then
      server/build/cli-bundle/makit --port $PORT stop 2>/dev/null || true
      sleep 1
      pkill -f "makit.*serve.*--port $PORT" || true
      echo "✓ daemon stopped (port $PORT)"
    else
      echo "✓ no daemon running on port $PORT"
    fi
    exit 0
    ;;
  --no-app)
    # Start daemon only (don't launch the app)
    ;;
  *)
    # Default: start daemon + launch app
    ;;
esac

# Ensure server is built
if [ ! -f server/build/cli-bundle/makit ]; then
  echo "==> Building server dist + CLI bundle …"
  (cd server && pnpm run build)
  ./scripts/bundle-makit-cli.sh server/build/cli-bundle
fi

# Start the daemon on the isolated profile
echo "==> Starting daemon on isolated profile …"
export MAKIT_HOME
mkdir -p "$MAKIT_HOME"

# Seed projects.json if not present (first run)
if [ ! -f "$MAKIT_HOME/projects.json" ]; then
  cat > "$MAKIT_HOME/projects.json" <<EOF
{
  "projects": [
    "/Users/le/Work/Vibe/makit"
  ]
}
EOF
fi

# Start daemon (detached, logging to MAKIT_HOME)
if pgrep -f "makit.*serve.*--port $PORT" >/dev/null 2>&1; then
  echo "✓ daemon already running on port $PORT"
else
  server/build/cli-bundle/makit serve --port $PORT --host 127.0.0.1 > /dev/null 2>&1 &
  sleep 2
  if ! pgrep -f "makit.*serve.*--port $PORT" >/dev/null 2>&1; then
    echo "✗ daemon failed to start"
    cat "$MAKIT_HOME/makit.log" 2>/dev/null || echo "(no log)"
    exit 1
  fi
  echo "✓ daemon started (pid $(pgrep -f "makit.*serve.*--port $PORT" | head -1), port $PORT)"
fi

# Extract fingerprint and generate test bearer
if [ ! -f "$SERVER_CERT" ]; then
  echo "✗ $SERVER_CERT not found (daemon didn't create it?)"
  exit 1
fi
FINGERPRINT=$(openssl x509 -in "$SERVER_CERT" -outform der | shasum -a 256 | cut -d' ' -f1)
BEARER=$(head -c 32 /dev/urandom | xxd -p)

echo "==> Daemon ready (loopback:$PORT)"
echo "    fingerprint: $FINGERPRINT"
echo "    bearer: $BEARER (test mode)"
echo ""

if [ "$1" = "--no-app" ]; then
  echo "✓ daemon running. To launch the app:"
  echo "  flutter run -d macos \\"
  echo "    --dart-define=MAKIT_WS_URL=wss://127.0.0.1:$PORT \\"
  echo "    --dart-define=MAKIT_FP=$FINGERPRINT"
  exit 0
fi

# Launch the app in debug mode
echo "==> Launching app (debug, hot reload enabled) …"
cd app
flutter run -d macos \
  --dart-define=MAKIT_WS_URL=wss://127.0.0.1:$PORT \
  --dart-define=MAKIT_FP=$FINGERPRINT
