#!/usr/bin/env bash
set -euo pipefail

MODE="stub"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "--mode requires an argument" >&2
        exit 2
      fi
      MODE="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "stub" && "$MODE" != "real" ]]; then
  echo "--mode must be stub or real" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_DIR="$ROOT/server"
APP_DIR="$ROOT/app"
PORT="9787"
BEARER="e2e-token"
FLUTTER_BIN="/Users/le/Work/Vibe/flutter/bin/flutter"
SIM_NAME="iPhone 17"
SERVER_LOG="$(mktemp -t pino-e2e-server.XXXXXX.log)"
SERVER_PID=""

APP_BUNDLE_ID="dev.pino.pino"

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  # Uninstall the test app so its seeded stub pairing (PINO_TEST_* written into
  # the simulator keychain by test_bootstrap) never leaks into a manual
  # `flutter run` session. Without this, the next live app boots trying to
  # reach the dead stub server instead of the user's real paired server.
  if [[ -n "${SIM_ID:-}" ]]; then
    xcrun simctl uninstall "$SIM_ID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

booted_sim_id() {
  xcrun simctl list devices available | awk -v name="$SIM_NAME" '
    index($0, name) && index($0, "Booted") {
      match($0, /\([0-9A-F-]+\)/);
      if (RSTART > 0) {
        print substr($0, RSTART + 1, RLENGTH - 2);
        exit;
      }
    }'
}

first_sim_id() {
  xcrun simctl list devices available | awk -v name="$SIM_NAME" '
    index($0, name) {
      match($0, /\([0-9A-F-]+\)/);
      if (RSTART > 0) {
        print substr($0, RSTART + 1, RLENGTH - 2);
        exit;
      }
    }'
}

SIM_ID="$(booted_sim_id)"
if [[ -z "$SIM_ID" ]]; then
  SIM_ID="$(first_sim_id)"
  if [[ -z "$SIM_ID" ]]; then
    echo "No available simulator named $SIM_NAME" >&2
    exit 1
  fi
  xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$SIM_ID" -b >/dev/null
fi

(
  cd "$SERVER_DIR"
  pnpm exec tsx test/e2e-server.ts \
    --port "$PORT" \
    --bearer "$BEARER" \
    --mode "$MODE" \
    --project "$ROOT"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

READY_JSON=""
for _ in {1..200}; do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "e2e server exited before ready; log:" >&2
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
  echo "timed out waiting for e2e server; log:" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

FP="$(node -e 'const fs=require("fs"); const j=JSON.parse(fs.readFileSync(0,"utf8")); process.stdout.write(j.fp)' <<<"$READY_JSON")"

cd "$APP_DIR"
set +e
PATH="/Users/le/Work/Vibe/flutter/bin:$PATH" "$FLUTTER_BIN" test integration_test/ \
  -d "$SIM_ID" \
  --dart-define=PINO_TEST_HOST=127.0.0.1 \
  --dart-define=PINO_TEST_PORT="$PORT" \
  --dart-define=PINO_TEST_BEARER="$BEARER" \
  --dart-define=PINO_TEST_FP="$FP"
flutter_exit=$?
set -e

if (( flutter_exit != 0 )); then
  echo "e2e server log: $SERVER_LOG" >&2
  tail -100 "$SERVER_LOG" >&2 || true
fi
exit "$flutter_exit"
