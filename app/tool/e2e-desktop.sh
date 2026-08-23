#!/usr/bin/env bash
set -euo pipefail

# Full-stack desktop control-plane e2e (SPEC-desktop-control-app). Boots the real daemon control
# socket (server/test/e2e-control-server.ts, StubAdapter — no real pi) and runs
# the real macOS desktop app against it (integration_test/desktop/). Counterpart
# to tool/e2e.sh, which does the mobile WS stack on an iOS simulator.
#
# RUN THIS IN THE BACKGROUND. The macOS app build is slow every time.
# A foreground run blocks the caller until it exits or is killed.
# Start a background process instead:
#
#   nohup ./app/tool/e2e-desktop.sh > /tmp/e2e-desktop.log 2>&1 &
#   # then poll: tail -5 /tmp/e2e-desktop.log
#
# macOS-only: the desktop control app is the `Platform.isMacOS` branch of
# main.dart, so the harness targets the `macos` device, not a simulator.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_DIR="$ROOT/server"
APP_DIR="$ROOT/app"

FLUTTER_BIN="${MAKIT_FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found — set MAKIT_FLUTTER_BIN or add flutter to PATH" >&2
  exit 1
fi
FLUTTER_BIN_DIR="$(cd "$(dirname "$FLUTTER_BIN")" && pwd)"

# Per-run private MAKIT_HOME so the harness never touches the real ~/.makit.
export MAKIT_HOME="$(mktemp -d -t makit-desktop-e2e.XXXXXX)"
SERVER_LOG="$(mktemp -t makit-desktop-e2e-server.XXXXXX.log)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$MAKIT_HOME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

(
  cd "$SERVER_DIR"
  pnpm exec tsx test/e2e-control-server.ts
) >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

READY_JSON=""
for _ in {1..200}; do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "control-server exited before ready; log:" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  READY_JSON="$(grep -m1 '"ready":true' "$SERVER_LOG" || true)"
  if [[ -n "$READY_JSON" ]]; then
    break
  fi
  sleep 0.1
done

if [[ -z "$READY_JSON" ]]; then
  echo "timed out waiting for control-server; log:" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

SOCK="$(node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(0,"utf8")); process.stdout.write(j.socket)' <<<"$READY_JSON")"

cd "$APP_DIR"
set +e
PATH="$FLUTTER_BIN_DIR:$PATH" "$FLUTTER_BIN" test integration_test/desktop/control_e2e_test.dart \
  -d macos \
  --dart-define=MAKIT_CONTROL_SOCK="$SOCK"
flutter_exit=$?
set -e

if (( flutter_exit != 0 )); then
  echo "control-server log: $SERVER_LOG" >&2
  tail -100 "$SERVER_LOG" >&2 || true
fi
exit "$flutter_exit"
