#!/usr/bin/env bash
set -euo pipefail

# Full-stack mobile WS e2e on an iOS simulator (StubAdapter — no API key).
# Counterpart to tool/e2e-desktop.sh, which does the macOS control plane.
#
# RUN THIS IN THE BACKGROUND. It needs an Xcode build and a simulator boot.
# A cold run needs many minutes. A warm run also needs minutes.
# A foreground run blocks the agent's tool call until it exits or is killed.
# Start a background process instead:
#
#   nohup ./app/tool/e2e.sh --mode=stub > /tmp/e2e.log 2>&1 &
#   # then poll: tail -5 /tmp/e2e.log
#
# The same applies to tool/e2e-desktop.sh and to `cd server && pnpm test`
# (~5.5 min). While iterating, prefer the one affected test file.

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
    --mode=*)
      MODE="${1#--mode=}"
      shift
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
# Overridable for CI / other machines. FLUTTER_BIN falls back to PATH; SIM_NAME
# picks the simulator model. In real mode the e2e server spawns the pi binary
# resolved from MAKIT_PI_BIN (default: `pi` on PATH), inherited via the env.
FLUTTER_BIN="${MAKIT_FLUTTER_BIN:-$(command -v flutter || true)}"
SIM_NAME="${MAKIT_SIM_NAME:-iPhone 17}"
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found — set MAKIT_FLUTTER_BIN or add flutter to PATH" >&2
  exit 1
fi
FLUTTER_BIN_DIR="$(cd "$(dirname "$FLUTTER_BIN")" && pwd)"
SERVER_LOG="$(mktemp -t makit-e2e-server.XXXXXX.log)"
SERVER_PID=""

APP_BUNDLE_ID="dev.getmakit.app"

free_port() {
  # Kill anything holding our test port. Strictly scoped to tcp:$PORT so we
  # never touch unrelated processes. Guards against a stray server from a
  # previous/aborted run (EADDRINUSE) that would otherwise fail readiness.
  local pids
  pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    echo "port $PORT busy (pids: $pids) — killing" >&2
    kill -9 $pids >/dev/null 2>&1 || true
    sleep 0.5
  fi
}

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  free_port
  # Uninstall the test app so its seeded stub pairing (MAKIT_TEST_* written into
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

# Ensure the port is free before starting (idempotent reruns / aborted runs).
free_port

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
# Each mode targets its own suite: stub asserts the StubAdapter's scripted
# scenarios; real_pi/ asserts what the genuine pi + fake model actually stream.
# Stub uses a single aggregate entrypoint (all_stub_test.dart) so the iOS app
# builds+launches ONCE instead of per-file — the dominant CI cost. The per-file
# sources under stub/ stay runnable individually for focused local iteration.
if [[ "$MODE" == "real" ]]; then
  TEST_TARGET="integration_test/real_pi"
else
  TEST_TARGET="integration_test/all_stub_test.dart"
fi
# Opt-in coverage (CI). Off by default so local/real runs stay fast and don't
# litter app/coverage/. When set, flutter writes coverage/lcov.info for upload.
COVERAGE_ARGS=()
if [[ -n "${MAKIT_E2E_COVERAGE:-}" ]]; then
  COVERAGE_ARGS+=(--coverage)
fi
set +e
PATH="$FLUTTER_BIN_DIR:$PATH" "$FLUTTER_BIN" test "$TEST_TARGET" \
  -d "$SIM_ID" \
  ${COVERAGE_ARGS[@]+"${COVERAGE_ARGS[@]}"} \
  --dart-define=MAKIT_TEST_HOST=127.0.0.1 \
  --dart-define=MAKIT_TEST_PORT="$PORT" \
  --dart-define=MAKIT_TEST_BEARER="$BEARER" \
  --dart-define=MAKIT_TEST_FP="$FP"
flutter_exit=$?
set -e

if (( flutter_exit != 0 )); then
  echo "e2e server log: $SERVER_LOG" >&2
  tail -100 "$SERVER_LOG" >&2 || true
fi
exit "$flutter_exit"
