#!/usr/bin/env bash
# Films the pending-message queue tour (SPEC-mid-turn-steering-and-queue/36) on a booted iOS simulator.
#
# Unlike tool/record-tour.sh (which films demo mode), this needs a LIVE server:
# the queue only exists while an agent is busy, and every step goes over the real
# wire (`send.message`, `queue.update`, `queue.reorder`, `queue.cancel`). So this
# boots server/test/e2e-server.ts with the StubAdapter — deterministic, keyless,
# no LLM — and drives integration_test/tour/pending_queue_tour.dart against it
# while `simctl io recordVideo` films the screen.
#
# Usage: tool/record-queue-tour.sh [output.mp4]
set -euo pipefail

OUT="${1:-/tmp/makit-pending-queue.mp4}"
RAW="$(mktemp -t makit-queue-tour.XXXXXX).mov"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_DIR="$ROOT/server"
APP_DIR="$ROOT/app"
# Overridable: 9787 is the shared e2e port, so a run in ANOTHER worktree holds
# it and this one dies at startup ("port is already in use").
PORT="${MAKIT_E2E_PORT:-9787}"
BEARER="e2e-token"
APP_BUNDLE_ID="dev.getmakit.app"

FLUTTER_BIN="${MAKIT_FLUTTER_BIN:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_BIN" ]]; then
  echo "flutter not found — set MAKIT_FLUTTER_BIN or add flutter to PATH" >&2
  exit 1
fi
SIM_NAME="${MAKIT_SIM_NAME:-iPhone 17}"

# A stale recorder from an earlier (timed-out) run holds a cleanup trap that
# pkills the stub server — including a NEW one. Refuse to start beside it rather
# than have it shoot this run down mid-tour.
if pgrep -f "record-queue-tour.sh" | grep -qv "^$$\$"; then
  others="$(pgrep -f "record-queue-tour.sh" | grep -v "^$$\$" | tr '\n' ' ')"
  if [[ -n "${others// /}" ]]; then
    echo "another recorder is still running (pid(s): $others) — stop it first:" >&2
    echo "  kill $others" >&2
    exit 1
  fi
fi

# `tsx` lives in server/node_modules, which is a pnpm store shared with every
# other worktree on this Mac: an install there can prune it out from under this
# run ("Command \"tsx\" not found"). Check before spending a build on it.
if [[ ! -x "$SERVER_DIR/node_modules/.bin/tsx" ]]; then
  echo "server/node_modules/.bin/tsx is missing — run: (cd server && pnpm install)" >&2
  exit 1
fi

DEVICE_ID="$(xcrun simctl list devices booted -j \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
ids=[x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"]
print(ids[0] if ids else "")')"

if [[ -z "$DEVICE_ID" ]]; then
  echo "no booted simulator — boot \"$SIM_NAME\" in Simulator.app first" >&2
  exit 1
fi
echo "recording on $DEVICE_ID"

# A previous run leaves paired credentials in the simulator keychain pointing at
# a dead server; the harness seeds its own, so start from a clean install.
xcrun simctl uninstall "$DEVICE_ID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true

MAKIT_HOME="$(mktemp -d -t makit-queue-tour.XXXXXX)"
export MAKIT_HOME
SERVER_LOG="$(mktemp -t makit-queue-tour-server.XXXXXX.log)"
SERVER_PID=""
REC_PID=""

cleanup() {
  if [[ -n "$REC_PID" ]] && kill -0 "$REC_PID" >/dev/null 2>&1; then
    # SIGINT, not SIGKILL: simctl only finalises the movie on a clean signal.
    kill -INT "$REC_PID" >/dev/null 2>&1 || true
    wait "$REC_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVER_PID" ]]; then
    pkill -f "e2e-server.ts --mode stub --port $PORT --project $ROOT" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$MAKIT_HOME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

(
  cd "$SERVER_DIR"
  pnpm exec tsx test/e2e-server.ts --mode stub --port "$PORT" --project "$ROOT"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

READY_JSON=""
for _ in {1..200}; do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "stub server exited before ready; log:" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  READY_JSON="$(grep -m1 '"ready":true' "$SERVER_LOG" || true)"
  [[ -n "$READY_JSON" ]] && break
  sleep 0.1
done
if [[ -z "$READY_JSON" ]]; then
  echo "timed out waiting for the stub server; log:" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi
# The app pins the server's self-signed cert, so the tour needs its fingerprint
# (same handshake as tool/e2e.sh).
FP="$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8")); process.stdout.write(j.fp ?? "")' <<<"$READY_JSON")"
if [[ -z "$FP" ]]; then
  echo "server ready line carried no cert fingerprint; log:" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi
echo "stub server ready on :$PORT"

xcrun simctl io "$DEVICE_ID" recordVideo --codec h264 --force "$RAW" &
REC_PID="$!"
sleep 1

set +e
(
  cd "$APP_DIR"
  "$FLUTTER_BIN" test --no-pub \
    -d "$DEVICE_ID" \
    --dart-define=MAKIT_TEST_HOST=127.0.0.1 \
    --dart-define=MAKIT_TEST_PORT="$PORT" \
    --dart-define=MAKIT_TEST_BEARER="$BEARER" \
    --dart-define=MAKIT_TEST_FP="$FP" \
    --dart-define=MAKIT_TOUR_BEAT_MS="${MAKIT_TOUR_BEAT_MS:-1600}" \
    integration_test/tour/pending_queue_tour.dart
)
TOUR_STATUS=$?
set -e

sleep 1
kill -INT "$REC_PID" >/dev/null 2>&1 || true
wait "$REC_PID" >/dev/null 2>&1 || true
REC_PID=""

if [[ $TOUR_STATUS -ne 0 ]]; then
  echo "tour failed (status $TOUR_STATUS); raw footage kept at $RAW" >&2
  exit "$TOUR_STATUS"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -y -loglevel error -i "$RAW" -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$OUT"
  rm -f "$RAW"
else
  echo "ffmpeg not found — keeping the raw .mov" >&2
  OUT="$RAW"
fi

echo "wrote $OUT"
